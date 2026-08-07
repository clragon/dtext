#include "dtext.h"
#include "html_sink.h"
#include "render.h"
#include "tree_sink.h"

#include <string.h>
#include <algorithm>
#include <tuple>

#ifdef DEBUG
#undef g_debug
#define STRINGIFY(x) XSTRINGIFY(x)
#define XSTRINGIFY(x) #x
#define g_debug(fmt, ...) fprintf(stderr, "\x1B[1;32mDEBUG\x1B[0m %-28.28s %-24.24s " fmt "\n", __FILE__ ":" STRINGIFY(__LINE__), __func__, ##__VA_ARGS__)
#else
#undef g_debug
#define g_debug(...)
#endif

static const size_t MAX_STACK_DEPTH = 512;

using ast::Node;
namespace NT = ast::NodeType;
namespace A = ast::Attr;

// Characters that mark the end of a link.
//
// http://www.fileformat.info/info/unicode/category/Pe/list.htm
// http://www.fileformat.info/info/unicode/block/cjk_symbols_and_punctuation/list.htm
static char32_t boundary_characters[] = {
  0x0021, // '!' U+0021 EXCLAMATION MARK
  0x0029, // ')' U+0029 RIGHT PARENTHESIS
  0x002C, // ',' U+002C COMMA
  0x002E, // '.' U+002E FULL STOP
  0x003A, // ':' U+003A COLON
  0x003B, // ';' U+003B SEMICOLON
  0x003C, // '<' U+003C LESS-THAN SIGN
  0x003E, // '>' U+003E GREATER-THAN SIGN
  0x003F, // '?' U+003F QUESTION MARK
  0x005D, // ']' U+005D RIGHT SQUARE BRACKET
  0x007D, // '}' U+007D RIGHT CURLY BRACKET
  0x276D, // '❭' U+276D MEDIUM RIGHT-POINTING ANGLE BRACKET ORNAMENT
  0x3000, // '　' U+3000 IDEOGRAPHIC SPACE (U+3000)
  0x3001, // '、' U+3001 IDEOGRAPHIC COMMA (U+3001)
  0x3002, // '。' U+3002 IDEOGRAPHIC FULL STOP (U+3002)
  0x3008, // '〈' U+3008 LEFT ANGLE BRACKET (U+3008)
  0x3009, // '〉' U+3009 RIGHT ANGLE BRACKET (U+3009)
  0x300A, // '《' U+300A LEFT DOUBLE ANGLE BRACKET (U+300A)
  0x300B, // '》' U+300B RIGHT DOUBLE ANGLE BRACKET (U+300B)
  0x300C, // '「' U+300C LEFT CORNER BRACKET (U+300C)
  0x300D, // '」' U+300D RIGHT CORNER BRACKET (U+300D)
  0x300E, // '『' U+300E LEFT WHITE CORNER BRACKET (U+300E)
  0x300F, // '』' U+300F RIGHT WHITE CORNER BRACKET (U+300F)
  0x3010, // '【' U+3010 LEFT BLACK LENTICULAR BRACKET (U+3010)
  0x3011, // '】' U+3011 RIGHT BLACK LENTICULAR BRACKET (U+3011)
  0x3014, // '〔' U+3014 LEFT TORTOISE SHELL BRACKET (U+3014)
  0x3015, // '〕' U+3015 RIGHT TORTOISE SHELL BRACKET (U+3015)
  0x3016, // '〖' U+3016 LEFT WHITE LENTICULAR BRACKET (U+3016)
  0x3017, // '〗' U+3017 RIGHT WHITE LENTICULAR BRACKET (U+3017)
  0x3018, // '〘' U+3018 LEFT WHITE TORTOISE SHELL BRACKET (U+3018)
  0x3019, // '〙' U+3019 RIGHT WHITE TORTOISE SHELL BRACKET (U+3019)
  0x301A, // '〚' U+301A LEFT WHITE SQUARE BRACKET (U+301A)
  0x301B, // '〛' U+301B RIGHT WHITE SQUARE BRACKET (U+301B)
  0x301C, // '〜' U+301C WAVE DASH (U+301C)
  0xFF09, // '）' U+FF09 FULLWIDTH RIGHT PARENTHESIS
  0xFF3D, // '］' U+FF3D FULLWIDTH RIGHT SQUARE BRACKET
  0xFF5D, // '｝' U+FF5D FULLWIDTH RIGHT CURLY BRACKET
  0xFF60, // '｠' U+FF60 FULLWIDTH RIGHT WHITE PARENTHESIS
  0xFF63, // '｣' U+FF63 HALFWIDTH RIGHT CORNER BRACKET
};

// Keeps RFC-3986 unreserved bytes and escapes the rest with uppercase hex. The
// parser escapes the URL here, so a href reaches the node finished and the
// renderer only escapes it for HTML in the attribute.
// ASCII alphanumeric, independent of locale. Ruby's escaper uses a fixed
// [a-zA-Z0-9] class, so a locale-sensitive isalnum would diverge on high bytes.
static bool is_ascii_alnum(unsigned char c) {
  return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}

static std::string uri_escape(const std::string_view s, const char whitelist = '-') {
  static const char hex[] = "0123456789ABCDEF";
  std::string out;
  out.reserve(s.size());
  for (const unsigned char c : s) {
    if (is_ascii_alnum(c) || c == '-' || c == '_' || c == '.' || c == '~' || c == whitelist) {
      out += c;
    } else {
      out += '%';
      out += hex[c >> 4];
      out += hex[c & 0x0F];
    }
  }
  return out;
}

// ASCII-only downcase. Ruby's wiki/post-search normalisation folds only A-Z
// (via String#downcase over ASCII here), leaving other bytes untouched.
static std::string ascii_lower(const std::string_view s) {
  std::string out(s);
  for (char& c : out) {
    if (c >= 'A' && c <= 'Z') c += 32;
  }
  return out;
}

// The bytes Ruby's String#strip trims. An [ltable] body is stripped before it
// splits into rows.
static bool is_ruby_space(unsigned char c) {
  return c == '\0' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r' || c == ' ';
}

static std::string ruby_strip(const std::string_view s) {
  size_t begin = 0;
  size_t end = s.size();
  while (begin < end && is_ruby_space(s[begin])) begin++;
  while (end > begin && is_ruby_space(s[end - 1])) end--;
  return std::string(s.substr(begin, end - begin));
}

// Split rows on '\n', matching ruby's `body.split(/\n/)`: a bare '\r' stays on
// the row, and trailing empty rows are dropped (ruby split without a limit).
static std::vector<std::string> split_ltable_rows(const std::string& s) {
  std::vector<std::string> rows;
  std::string row;
  for (char c : s) {
    if (c == '\n') {
      rows.push_back(row);
      row.clear();
    } else {
      row += c;
    }
  }
  rows.push_back(row);
  while (!rows.empty() && rows.back().empty()) rows.pop_back();
  return rows;
}

// Split cells on '|', matching ruby's `row.split(/(?<!\\)\|/)`: a '|' preceded
// by a backslash is literal (and keeps the backslash), and trailing empty
// cells are dropped.
static std::vector<std::string> split_ltable_cells(const std::string& s) {
  std::vector<std::string> cells;
  std::string cell;
  for (size_t i = 0; i < s.size(); i++) {
    if (s[i] == '|' && (i == 0 || s[i - 1] != '\\')) {
      cells.push_back(cell);
      cell.clear();
    } else {
      cell += s[i];
    }
  }
  cells.push_back(cell);
  while (!cells.empty() && cells.back().empty()) cells.pop_back();
  return cells;
}

// Turns an [ltable] body into the [table] markup it stands for, the first row a
// [thead] of [th] cells and the rest [tbody] rows of [td] cells. The body parses
// in a nested pass that closes the table at its end, so a construct in a cell
// cannot consume the text after [/ltable]. An empty body yields
// "[table][/tbody][/table]", and the table machinery emits that stray [/tbody]
// as literal text.
static std::string expand_ltable(const std::string_view body) {
  std::vector<std::string> rows = split_ltable_rows(ruby_strip(body));

  std::string out = "[table]";
  for (size_t r = 0; r < rows.size(); r++) {
    std::vector<std::string> cells = split_ltable_cells(rows[r]);
    if (r == 0) {
      out += "[thead][tr]";
      for (const auto& cell : cells) out += "[th]" + cell + "[/th]";
      out += "[/tr][/thead][tbody]";
    } else {
      out += "[tr]";
      for (const auto& cell : cells) out += "[td]" + cell + "[/td]";
      out += "[/tr]";
    }
  }
  out += "[/tbody][/table]";
  return out;
}

%%{
machine dtext;

access sm->;
variable p sm->p;
variable pe sm->pe;
variable eof sm->eof;
variable top sm->top_state;
variable ts sm->ts;
variable te sm->te;
variable act sm->act;
variable stack (sm->stack.data());

prepush {
  size_t len = stack.size();

  // Should never happen.
  if (len > MAX_STACK_DEPTH) {
    throw DTextError("too many nested elements");
  }

  if (sm->top_state >= len) {
    g_debug("growing stack %zi\n", len + 16);
    stack.resize(len + 16, 0);
  }
}

action mark_a1 { a1 = p; }
action mark_a2 { a2 = p; }
action mark_b1 { b1 = p; }
action mark_b2 { b2 = p; }

action in_quote { dstack_is_open(BLOCK_QUOTE) }
action in_section { dstack_is_open(BLOCK_SECTION) }
# Guards the [ltable] rule off inside an expansion, so a nested [ltable] stays
# literal and emit_ltable cannot recurse.
action outside_expansion { !in_expansion }

newline = '\r\n' | '\n';

nonnewline = any - (newline | '\r');
nonquote = ^'"';
nonbracket = ^']';
nonpipe = ^'|';
nonpipebracket = nonpipe & nonbracket;
noncurly = ^'}';
nonpipecurly = nonpipe & noncurly;

url = 'http'i 's'i? '://' ^space+;
delimited_url = '<' url >mark_a1 %mark_a2 :>> '>';
internal_url = [/#] ^space+;
basic_textile_link = '"' nonquote+ >mark_a1 %mark_a2 '":' (url | internal_url) >mark_b1 %mark_b2;
bracketed_textile_link = '"' nonquote+ >mark_a1 %mark_a2 '":[' (url | internal_url) >mark_b1 %mark_b2 :>> ']';

basic_wiki_link = '[[' (nonbracket nonpipebracket*) >mark_a1 %mark_a2 ']]';
aliased_wiki_link = '[[' nonpipebracket+ >mark_a1 %mark_a2 '|' nonpipebracket+ >mark_b1 %mark_b2 ']]';

basic_post_search_link = '{{' (noncurly nonpipecurly*) >mark_a1 %mark_a2 '}}';
aliased_post_search_link = '{{' nonpipecurly+ >mark_a1 %mark_a2 '|' nonpipecurly+ >mark_b1 %mark_b2 '}}';

spoilers_open = '[spoiler'i 's'i? ']';
spoilers_close = '[/spoiler'i 's'i? ']';

color_name = (
  # Tag Categories
    'gen'i ('eral'i)?
  | 'art'i ('ist'i)?
  | 'dir'i ('ect'i ('or'i)?)?
  | 'cont'i ('ributor'i)?
  | 'copy'i ('right'i)?
  | 'fr'i ('anc'i? ('hise'i)?)?
  | 'ch'i ('ar'i ('acter'i)?)?
  | 'oc'i
  | 'spec'i ('ies'i)?
  | 'inv'i ('alid'i)?
  | 'meta'i
  | 'lor'i ('e'i)?
  # User Groups
  | 'admin'i
  | 'mod'i ('erator'i)?
  | 'jan'i ('itor'i)?
  | 'former'i ('-staff'i)?
  | 'priv'i ('ileged'i)?
  | 'member'i
  | 'blocked'i
  );

color_value = (([a-z]+ - color_name) | '#'i[0-9a-fA-F]{3,6});

color_open = '[color='i color_value >mark_a1 %mark_a2 ']';
color_typed = '[color='i color_name >mark_a1 %mark_a2 ']';
color_close = '[/color]'i;

id = digit+ >mark_a1 %mark_a2;
page = digit+ >mark_b1 %mark_b2;

post_id = 'post #'i id;
post_changes_for_id = 'post changes #'i id;
thumb_id = 'thumb #'i id;
post_flag_id = 'flag #'i id;
note_id = 'note #'i id;
forum_post_id = 'forum #'i id;
forum_topic_id = 'topic #'i id;
comment_id = 'comment #'i id;
pool_id = 'pool #'i id;
user_id = 'user #'i id;
artist_id = 'artist #'i id;
ban_id = 'ban #'i id;
bulk_update_request_id = 'bur #'i id;
tag_alias_id = 'alias #'i id;
tag_implication_id = 'implication #'i id;
mod_action_id = 'mod action #'i id;
user_feedback_id = 'record #'i id;
wiki_page_id = 'wiki #'i id;
set_id = 'set #'i id;
blip_id = 'blip #'i id;
takedown_id = 'take'i ' 'i? 'down 'i 'request 'i? '#'i id;
ticket_id = 'ticket #'i id;
appeal_id = 'appeal #'i id;

ws = ' ' | '\t';
nonperiod = graph - ('.' | '"');
header = 'h'i [123456] >mark_a1 %mark_a2 '.' ws*;

section_open = '[section]'i;
section_open_expanded = '[section,expanded]'i;
section_open_aliased = '[section='i (nonbracket+ >mark_a1 %mark_a2) ']';
section_open_aliased_expanded = '[section,expanded='i (nonbracket+ >mark_a1 %mark_a2) ']';
section_close = '[/section'i (']' when in_section);

quote_open = '[quote]'i;
quote_open_colored_typed = '[quote='i color_name >mark_a1 %mark_a2 ']';
quote_open_colored = '[quote='i color_value >mark_a1 %mark_a2 ']';
quote_close = '[/quote'i (']' when in_quote);

internal_anchor = '[#' ((alnum | [_\-])+ >mark_a1 %mark_a2) ']';

list_item = '*'+ >mark_a1 %mark_a2 ws+ nonnewline+ >mark_b1 %mark_b2;

basic_inline := |*
  '[b]'i    => { dstack_open_inline(INLINE_B); };
  '[/b]'i   => { dstack_close_inline(INLINE_B); };
  '[i]'i    => { dstack_open_inline(INLINE_I); };
  '[/i]'i   => { dstack_close_inline(INLINE_I); };
  '[s]'i    => { dstack_open_inline(INLINE_S); };
  '[/s]'i   => { dstack_close_inline(INLINE_S); };
  '[u]'i    => { dstack_open_inline(INLINE_U); };
  '[/u]'i   => { dstack_close_inline(INLINE_U); };
  '[sup]'i  => {
    if (dstack_count(INLINE_SUP) + dstack_count(INLINE_SUB) < 3) {
      dstack_open_inline(INLINE_SUP);
    } else {
      ignored_sup_sub_tags++;
    }
  };
  '[/sup]'i => {
    if (ignored_sup_sub_tags > 0) {
      ignored_sup_sub_tags--;
    } else {
      dstack_close_inline(INLINE_SUP);
    }
  };
  '[sub]'i  => {
    if (dstack_count(INLINE_SUP) + dstack_count(INLINE_SUB) < 3) {
      dstack_open_inline(INLINE_SUB);
    } else {
      ignored_sup_sub_tags++;
    }
  };
  '[/sub]'i => {
    if (ignored_sup_sub_tags > 0) {
      ignored_sup_sub_tags--;
    } else {
      dstack_close_inline(INLINE_SUB);
    }
  };
  any => { append_text(fc); };
*|;

inline := |*
  '\\`' => {
    append_text('`');
  };

  '`' => {
    dstack_open_inline(INLINE_CODE);
    fcall inline_code;
  };

  internal_anchor => {
    sink.internal_anchor({ a1, a2 });
  };

  thumb_id => {
    sink.id_link("thumb", { a1, a2 });
  };

  post_id => { sink.id_link("post", { a1, a2 }); };
  post_changes_for_id => { sink.id_link("post_changes", { a1, a2 }); };
  post_flag_id => { sink.id_link("flag", { a1, a2 }); };
  note_id => { sink.id_link("note", { a1, a2 }); };
  forum_post_id => { sink.id_link("forum_post", { a1, a2 }); };
  forum_topic_id => { sink.id_link("topic", { a1, a2 }); };
  comment_id => { sink.id_link("comment", { a1, a2 }); };
  pool_id => { sink.id_link("pool", { a1, a2 }); };
  user_id => { sink.id_link("user", { a1, a2 }); };
  artist_id => { sink.id_link("artist", { a1, a2 }); };
  ban_id => { sink.id_link("ban", { a1, a2 }); };
  bulk_update_request_id => { sink.id_link("bur", { a1, a2 }); };
  tag_alias_id => { sink.id_link("alias", { a1, a2 }); };
  tag_implication_id => { sink.id_link("implication", { a1, a2 }); };
  mod_action_id => { sink.id_link("mod_action", { a1, a2 }); };
  user_feedback_id => { sink.id_link("record", { a1, a2 }); };
  wiki_page_id => { sink.id_link("wiki", { a1, a2 }); };
  set_id => { sink.id_link("set", { a1, a2 }); };
  blip_id => { sink.id_link("blip", { a1, a2 }); };
  ticket_id => { sink.id_link("ticket", { a1, a2 }); };
  appeal_id => { sink.id_link("appeal", { a1, a2 }); };
  takedown_id => { sink.id_link("takedown", { a1, a2 }); };

  basic_post_search_link => {
    emit_post_search_link({ a1, a2 }, { a1, a2 });
  };

  aliased_post_search_link => {
    emit_post_search_link({ a1, a2 }, { b1, b2 });
  };

  basic_wiki_link => {
    emit_wiki_link({ a1, a2 }, { a1, a2 });
  };

  aliased_wiki_link => {
    emit_wiki_link({ a1, a2 }, { b1, b2 });
  };

  basic_textile_link => {
    const char* match_end = b2;
    const char* url_start = b1;
    const char* url_end = find_boundary_c(match_end - 1) + 1;

    emit_named_url({ url_start, url_end }, { a1, a2 });

    if (url_end < match_end) {
      append_text({ url_end, match_end });
    }
  };

  bracketed_textile_link => {
    emit_named_url({ b1, b2 }, { a1, a2 });
  };

  url => {
    const char* match_end = te;
    const char* url_start = ts;
    const char* url_end = find_boundary_c(match_end - 1) + 1;

    sink.unnamed_url({ url_start, url_end });

    if (url_end < match_end) {
      append_text({ url_end, match_end });
    }
  };

  delimited_url => {
    sink.unnamed_url({ a1, a2 });
  };

  newline list_item => {
    g_debug("inline list");
    fexec ts + 1;
    fret;
  };

  '[b]'i  => { dstack_open_inline(INLINE_B); };
  '[/b]'i => { dstack_close_inline(INLINE_B); };
  '[i]'i  => { dstack_open_inline(INLINE_I); };
  '[/i]'i => { dstack_close_inline(INLINE_I); };
  '[s]'i  => { dstack_open_inline(INLINE_S); };
  '[/s]'i => { dstack_close_inline(INLINE_S); };
  '[u]'i  => { dstack_open_inline(INLINE_U); };
  '[/u]'i => { dstack_close_inline(INLINE_U); };
  '[sup]'i  => {
    if (dstack_count(INLINE_SUP) + dstack_count(INLINE_SUB) < 3) {
      dstack_open_inline(INLINE_SUP);
    } else {
      ignored_sup_sub_tags++;
    }
  };
  '[/sup]'i => {
    if (ignored_sup_sub_tags > 0) {
      ignored_sup_sub_tags--;
    } else {
      dstack_close_inline(INLINE_SUP);
    }
  };
  '[sub]'i  => {
    if (dstack_count(INLINE_SUP) + dstack_count(INLINE_SUB) < 3) {
      dstack_open_inline(INLINE_SUB);
    } else {
      ignored_sup_sub_tags++;
    }
  };
  '[/sub]'i => {
    if (ignored_sup_sub_tags > 0) {
      ignored_sup_sub_tags--;
    } else {
      dstack_close_inline(INLINE_SUB);
    }
  };

  color_typed => {
    if (allow_color) {
      open_colored_span({ a1, a2 }, true);
    }
    fgoto inline;
  };

  color_open => {
    if (allow_color) {
      open_colored_span({ a1, a2 }, false);
    }
    fgoto inline;
  };

  color_close => {
    if (allow_color) {
      dstack_close_inline(INLINE_COLOR);
    }
    fgoto inline;
  };

  spoilers_open => {
    dstack_open_inline(INLINE_SPOILER);
  };

  newline* spoilers_close => {
    g_debug("inline [/spoiler]");
    dstack_close_before_block();

    if (dstack_check(INLINE_SPOILER)) {
      dstack_close_inline(INLINE_SPOILER);
    } else if (dstack_close_block(BLOCK_SPOILER)) {
      fret;
    }
  };

  # these are block level elements that should kick us out of the inline
  # scanner

  newline header => {
    dstack_close_leaf_blocks();
    fexec ts;
    fret;
  };

  '[table]'i => {
    dstack_close_before_block();
    fexec ts;
    fret;
  };

  '[ltable]'i when outside_expansion => {
    dstack_close_before_block();
    fexec ts;
    fret;
  };

  '[/table]'i space* => {
    g_debug("inline [/table]");
    dstack_close_before_block();

    if (dstack_check(BLOCK_LI)) {
      dstack_close_list();
    }

    if (dstack_check(BLOCK_TABLE)) {
      dstack_rewind();
      fret;
    } else {
      append_raw_block("[/table]");
    }
  };

  '[code]'i => {
    dstack_close_before_block();
    fexec ts;
    fret;
  };

  '[/code]'i space* => {
    g_debug("inline [/code]");
    dstack_close_before_block();

    if (dstack_check(BLOCK_LI)) {
      dstack_close_list();
    }

    if (dstack_check(BLOCK_CODE)) {
      dstack_rewind();
      fret;
    } else {
      append_raw_block("[/code]");
    }
  };

  quote_open => {
    g_debug("inline [quote]");
    dstack_close_leaf_blocks();
    fexec ts;
    fret;
  };

  quote_open_colored => {
    g_debug("inline [quote=color]");
    dstack_close_leaf_blocks();
    fexec ts;
    fret;
  };

  quote_open_colored_typed => {
    g_debug("inline [quote=type]");
    dstack_close_leaf_blocks();
    fexec ts;
    fret;
  };

  newline? quote_close ws* => {
    g_debug("inline [/quote]");
    dstack_close_until(BLOCK_QUOTE);
    fret;
  };

  (section_open | section_open_expanded | section_open_aliased | section_open_aliased_expanded) => {
    g_debug("inline [section]");
    dstack_close_leaf_blocks();
    fexec ts;
    fret;
  };

  newline? section_close ws* => {
    g_debug("inline [/expand]");
    dstack_close_until(BLOCK_SECTION);
    fret;
  };

  '[/th]'i => {
    if (dstack_close_block(BLOCK_TH)) {
      fret;
    }
  };

  newline* '[/td]'i => {
    if (dstack_close_block(BLOCK_TD)) {
      fret;
    }
  };

  newline{2,} => {
    g_debug("inline newline2");
    g_debug("  return");

    dstack_close_list();

    fexec ts;
    fret;
  };

  newline => {
    g_debug("inline newline");

    if (header_mode) {
      dstack_close_leaf_blocks();
      fret;
    } else if (dstack_is_open(BLOCK_UL)) {
      dstack_close_list();
      fret;
    } else {
      append_line_break();
    }
  };

  '\r' => {
    append_text(' ');
  };

  any => {
    g_debug("inline char: %c", fc);
    append_text(fc);
  };
*|;

inline_code := |*
  '\\`' => {
    append_content('`');
  };

  '`' => {
    dstack_close_inline(INLINE_CODE);
    fret;
  };

  any => {
    append_content(fc);
  };
*|;

ltable := |*
  '[/ltable]'i => {
    emit_ltable();
    fret;
  };

  any => {
    ltable_buffer.push_back(fc);
  };
*|;

code := |*
  '[/code]'i => {
    if (dstack_check(BLOCK_CODE)) {
      dstack_rewind();
    } else {
      append_content("[/code]");
    }
    fret;
  };

  any => {
    append_content(fc);
  };
*|;

table := |*
  '[ltable]'i when outside_expansion => {
    ltable_buffer.clear();
    in_ltable = true;
    fcall ltable;
  };

  '[thead]'i => {
    dstack_open_block(BLOCK_THEAD);
  };

  '[/thead]'i => {
    dstack_close_block(BLOCK_THEAD);
  };

  '[tbody]'i => {
    dstack_open_block(BLOCK_TBODY);
  };

  '[/tbody]'i => {
    dstack_close_block(BLOCK_TBODY);
  };

  '[th]'i => {
    dstack_open_block(BLOCK_TH);
    fcall inline;
  };

  '[tr]'i => {
    dstack_open_block(BLOCK_TR);
  };

  '[/tr]'i => {
    dstack_close_block(BLOCK_TR);
  };

  '[td]'i => {
    dstack_open_block(BLOCK_TD);
    fcall inline;
  };

  '[/table]'i => {
    if (dstack_close_block(BLOCK_TABLE)) {
      fret;
    }
  };

  any;
*|;

main := |*
  header => {
    element_t block = (element_t)(BLOCK_H1 + (*a1 - '1'));

    dstack_open_block(block);

    header_mode = true;
    fcall inline;
  };

  quote_open space* => {
    dstack_close_leaf_blocks();
    dstack_open_block(BLOCK_QUOTE);
  };

  quote_open_colored_typed => {
    dstack_close_leaf_blocks();
    open_colored_quote({ a1, a2 }, true);
  };

  quote_open_colored => {
    dstack_close_leaf_blocks();
    open_colored_quote({ a1, a2 }, false);
  };

  spoilers_open space* => {
    dstack_close_leaf_blocks();
    dstack_open_block(BLOCK_SPOILER);
  };

  spoilers_close => {
    g_debug("block [/spoiler]");
    dstack_close_before_block();
    if (dstack_check(BLOCK_SPOILER)) {
      g_debug("  rewind");
      dstack_rewind();
    }
  };

  '[code]'i space* => {
    dstack_close_leaf_blocks();
    dstack_open_block(BLOCK_CODE);
    fcall code;
  };

  section_open space* => {
    append_section({}, false);
  };

  section_open_expanded space* => {
    append_section({}, true);
  };

  section_open_aliased space* => {
    g_debug("block [section=]");
    append_section({ a1, a2 }, false);
  };

  section_open_aliased_expanded space* => {
    g_debug("block expanded [section=]");
    append_section({ a1, a2 }, true);
  };

  '[table]'i => {
    dstack_close_leaf_blocks();
    dstack_open_block(BLOCK_TABLE);
    fcall table;
  };

  '[ltable]'i when outside_expansion => {
    ltable_buffer.clear();
    in_ltable = true;
    fcall ltable;
  };

  list_item => {
    g_debug("block list");
    dstack_open_list(a2 - a1);
    fexec b1;
    fcall inline;
  };

  newline{2,} => {
    g_debug("block newline2");

    if (header_mode) {
      dstack_close_leaf_blocks();
    } else if (dstack_is_open(BLOCK_UL)) {
      dstack_close_until(BLOCK_UL);
    } else {
      dstack_close_before_block();
    }
  };

  newline => {
    g_debug("block newline");
  };

  any => {
    g_debug("block char: %c", fc);
    fhold;

    if (dstack.empty() || dstack_check(BLOCK_QUOTE) || dstack_check(BLOCK_SPOILER) || dstack_check(BLOCK_SECTION)) {
      dstack_open_block(BLOCK_P);
    }

    fcall inline;
  };
*|;

}%%

%% write data;

template <class SinkT>
void StateMachine<SinkT>::dstack_push(element_t element) {
  dstack.push_back(element);
  sink.open(element);
}

template <class SinkT>
element_t StateMachine<SinkT>::dstack_peek() {
  return dstack.empty() ? DSTACK_EMPTY : dstack.back();
}

template <class SinkT>
bool StateMachine<SinkT>::dstack_check(element_t expected_element) {
  return dstack_peek() == expected_element;
}

template <class SinkT>
bool StateMachine<SinkT>::dstack_is_open(element_t element) {
  return std::find(dstack.begin(), dstack.end(), element) != dstack.end();
}

template <class SinkT>
int StateMachine<SinkT>::dstack_count(element_t element) {
  return std::count(dstack.begin(), dstack.end(), element);
}

template <class SinkT>
void StateMachine<SinkT>::append_line_break() {
  sink.line_break();
}

// Text and code bodies go straight to the sink, with no buffer in between.
template <class SinkT>
void StateMachine<SinkT>::append_text(const std::string_view text) {
  sink.text(text);
}

template <class SinkT>
void StateMachine<SinkT>::append_text(char c) {
  sink.text(std::string_view(&c, 1));
}

template <class SinkT>
void StateMachine<SinkT>::append_content(const std::string_view text) {
  sink.content(text);
}

template <class SinkT>
void StateMachine<SinkT>::append_content(char c) {
  sink.content(std::string_view(&c, 1));
}

template <class SinkT>
void StateMachine<SinkT>::append_raw_block(const std::string_view text) {
  sink.raw_block(text);
}

template <class SinkT>
void StateMachine<SinkT>::emit_named_url(const std::string_view url, const std::string_view title) {
  sink.named_url(url, parse_basic_inline(title));
}

template <class SinkT>
void StateMachine<SinkT>::emit_wiki_link(const std::string_view tag, const std::string_view title) {
  std::string normalized_tag(tag);
  std::transform(normalized_tag.begin(), normalized_tag.end(), normalized_tag.begin(),
                 [](unsigned char c) { return c == ' ' ? '_' : (c >= 'A' && c <= 'Z' ? c + 32 : c); });

  // FIXME: Take the anchor as an argument here (mirrors the ruby comment).
  std::string href;
  if (tag[0] == '#') {
    href = "#" + uri_escape(normalized_tag.substr(1));
  } else {
    // The '#' whitelist keeps a literal '#' in the ?title= query (ruby passes
    // '#' as the whitelist byte), so a tag anchor stays readable in the href
    // rather than becoming %23.
    href = "/wiki_pages/show_or_new?title=" + uri_escape(normalized_tag, '#');
  }

  sink.wiki_link(href, title);
}

template <class SinkT>
void StateMachine<SinkT>::emit_post_search_link(const std::string_view tag, const std::string_view title) {
  std::string href = "/posts?tags=" + uri_escape(ascii_lower(tag));
  sink.post_search_link(href, title);
}

template <class SinkT>
void StateMachine<SinkT>::emit_ltable() {
  in_ltable = false;

  // Close leaf blocks first, the way the block [table] rule does before it
  // opens, so a preceding paragraph ends before the table rather than being
  // pulled into it.
  std::string expanded = expand_ltable(ltable_buffer);
  dstack_close_leaf_blocks();

  // Parse the expansion into the same sink. A nested machine keeps its own
  // ragel state and dstack, but every open/close it emits is routed to the
  // shared sink, so the table attaches to this parser's current container.
  StateMachine<SinkT> nested(expanded, dtext_en_main, allow_color, sink, /*in_expansion=*/true);
  nested.run();
}

template <class SinkT>
void StateMachine<SinkT>::append_section(const std::string_view summary, bool initially_open) {
  dstack_close_leaf_blocks();
  dstack.push_back(BLOCK_SECTION);
  std::string title(summary);
  sink.open_section(summary.empty() ? nullptr : &title, initially_open);
}

template <class SinkT>
void StateMachine<SinkT>::dstack_open_block(element_t type) {
  dstack_push(type);
}

template <class SinkT>
void StateMachine<SinkT>::dstack_open_inline(element_t type) {
  dstack_push(type);
}

template <class SinkT>
void StateMachine<SinkT>::open_colored_quote(std::string_view color, bool category) {
  dstack.push_back(BLOCK_QUOTE);
  std::string value(color);
  sink.open_quote(&value, category);
}

template <class SinkT>
void StateMachine<SinkT>::open_colored_span(std::string_view color, bool category) {
  dstack.push_back(INLINE_COLOR);
  sink.open_color(color, category);
}

template <class SinkT>
void StateMachine<SinkT>::dstack_close_inline(element_t type) {
  if (dstack_check(type)) {
    dstack_rewind();
  } else {
    append_text(std::string_view(ts, te - ts));
  }
}

template <class SinkT>
bool StateMachine<SinkT>::dstack_close_block(element_t type) {
  if (dstack_check(type)) {
    dstack_rewind();
    return true;
  } else {
    append_raw_block(std::string_view(ts, te - ts));
    return false;
  }
}

// Closes the innermost open element. Trimming a trailing <br> and an empty <p>
// is left to the renderer, because a span hidden by allow_color can bury the
// last <br>. The HTML sink trims, and the tree keeps the raw shape.
template <class SinkT>
void StateMachine<SinkT>::dstack_rewind() {
  element_t element = dstack.back();
  dstack.pop_back();

  switch (element) {
    case BLOCK_TR: case BLOCK_UL: case BLOCK_LI:
    case BLOCK_H1: case BLOCK_H2: case BLOCK_H3:
    case BLOCK_H4: case BLOCK_H5: case BLOCK_H6:
      header_mode = false;
      break;

    default:
      break;
  }

  sink.close(element);
}

template <class SinkT>
void StateMachine<SinkT>::dstack_close_before_block() {
  while (dstack_check(BLOCK_P) || dstack_check(BLOCK_LI) || dstack_check(BLOCK_UL)) {
    dstack_rewind();
  }
}

template <class SinkT>
void StateMachine<SinkT>::dstack_close_all() {
  while (!dstack.empty()) {
    dstack_rewind();
  }
}

// container blocks: [quote], [spoiler], [section]
// leaf blocks: [code], [table], [td]?, [th]?, <h1>, <p>, <li>, <ul>
template <class SinkT>
void StateMachine<SinkT>::dstack_close_leaf_blocks() {
  while (!dstack.empty() && !dstack_check(BLOCK_QUOTE) && !dstack_check(BLOCK_SPOILER) && !dstack_check(BLOCK_SECTION)) {
    dstack_rewind();
  }
}

template <class SinkT>
void StateMachine<SinkT>::dstack_close_until(element_t element) {
  while (!dstack.empty() && !dstack_check(element)) {
    dstack_rewind();
  }

  dstack_rewind();
}

template <class SinkT>
void StateMachine<SinkT>::dstack_open_list(int depth) {
  if (dstack_is_open(BLOCK_LI)) {
    dstack_close_until(BLOCK_LI);
  } else {
    dstack_close_leaf_blocks();
  }

  while (dstack_count(BLOCK_UL) < depth) {
    dstack_open_block(BLOCK_UL);
  }

  while (dstack_count(BLOCK_UL) > depth) {
    dstack_close_until(BLOCK_UL);
  }

  dstack_open_block(BLOCK_LI);
}

template <class SinkT>
void StateMachine<SinkT>::dstack_close_list() {
  while (dstack_is_open(BLOCK_UL)) {
    dstack_close_until(BLOCK_UL);
  }
}

static inline std::tuple<char32_t, int> get_utf8_char(const char* c) {
  const unsigned char* p = reinterpret_cast<const unsigned char*>(c);

  // 0x10xxxxxx is a UTF-8 continuation byte.
  while ((p[0] >> 6) == 0b10) {
    p--;
  }

  if (p[0] >> 7 == 0) {
    // 0x0xxxxxxx
    return { p[0], 1 };
  } else if ((p[0] >> 5) == 0b110) {
    // 0x110xxxxx, 0x10xxxxxx
    return { ((p[0] & 0b00011111) << 6) | (p[1] & 0b00111111), 2 };
  } else if ((p[0] >> 4) == 0b1110) {
    // 0x1110xxxx, 0x10xxxxxx, 0x10xxxxxx
    return { ((p[0] & 0b00001111) << 12) | (p[1] & 0b00111111) << 6 | (p[2] & 0b00111111), 3 };
  } else if ((p[0] >> 3) == 0b11110) {
    // 0x11110xxx, 0x10xxxxxx, 0x10xxxxxx, 0x10xxxxxx
    return { ((p[0] & 0b00000111) << 18) | (p[1] & 0b00111111) << 12 | (p[2] & 0b00111111) << 6 | (p[3] & 0b00111111), 4 };
  } else {
    return { 0, 0 };
  }
}

// Returns the preceding non-boundary character if `c` is a boundary character.
// Otherwise, returns `c` if `c` is not a boundary character. Boundary characters
// are trailing punctuation characters that should not be part of the matched text.
static inline const char* find_boundary_c(const char* c) {
  auto [ch, len] = get_utf8_char(c);

  if (std::binary_search(std::begin(boundary_characters), std::end(boundary_characters), ch)) {
    return c - len;
  } else {
    return c;
  }
}

template <class SinkT>
StateMachine<SinkT>::StateMachine(const std::string_view dtext, int initial_state, bool allow_color, SinkT& sink, bool in_expansion)
    : sink(sink), allow_color(allow_color), in_expansion(in_expansion) {
  stack.reserve(16);
  dstack.reserve(16);

  p = dtext.data();
  pb = p;
  pe = p + dtext.size();
  eof = pe;
  cs = initial_state;
}

template <class SinkT>
void StateMachine<SinkT>::run() {
  auto* sm = this;
  g_debug("start\n");

  %% write init nocs;
  %% write exec;

  // A [ltable] with no closing tag runs to EOF; flush the captured body so an
  // unterminated legacy table still renders (ruby's regex allowed \z to close).
  if (in_ltable) {
    emit_ltable();
  }

  sm->dstack_close_all();
}

// The tree builder and the HTML emitter are the only sinks, so the machine is
// generated once for each.
template class StateMachine<sink::TreeSink>;
template class StateMachine<HtmlSink>;

std::vector<ast::Node> parse_basic_inline(const std::string_view dtext) {
  // The basic-inline machine has no color rule, so allow_color is moot here.
  sink::TreeSink tree;
  StateMachine<sink::TreeSink> sm(dtext, dtext_en_basic_inline, false, tree);
  sm.run();
  return std::move(tree.take_document().children);
}

ast::Node parse_to_ast(const std::string_view dtext, bool allow_color) {
  sink::TreeSink tree;
  StateMachine<sink::TreeSink> sm(dtext, dtext_en_main, allow_color, tree);
  sm.run();
  return tree.take_document();
}

render::Result render::to_html(const std::string_view dtext, bool allow_color, const render::Options& options) {
  HtmlSink sink(options);
  sink.out.reserve(dtext.size() + dtext.size() / 2 + 64);
  StateMachine<HtmlSink> sm(dtext, dtext_en_main, allow_color, sink);
  sm.run();
  return sink.take_result();
}
