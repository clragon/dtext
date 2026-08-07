#ifndef DTEXT_HTML_SINK_H
#define DTEXT_HTML_SINK_H

#include <charconv>
#include <cstdlib>
#include <string>
#include <string_view>
#include <unordered_map>

#include "ast.h"
#include "element.h"
#include "render.h"
#include "sink.h"

// The parser writes HTML through this sink as it recognizes markup. It sits in
// a header because the parser is a template on its sink, and the build happens
// where the ragel tables are.
namespace html_sink_detail {

inline const std::string* str_attr(const ast::Node& node, const char* key) {
  for (const auto& [k, v] : node.attrs) {
    if (k == key && std::holds_alternative<std::string>(v)) {
      return &std::get<std::string>(v);
    }
  }
  return nullptr;
}

inline void escape_into(std::string& out, const std::string_view s) {
  for (const char c : s) {
    switch (c) {
      case '&': out += "&amp;"; break;
      case '<': out += "&lt;"; break;
      case '>': out += "&gt;"; break;
      case '"': out += "&quot;"; break;
      default: out += c;
    }
  }
}

inline std::string html_escape(const std::string_view s) {
  std::string out;
  escape_into(out, s);
  return out;
}

inline std::string uri_escape(const std::string_view s) {
  static const char hex[] = "0123456789ABCDEF";
  std::string out;
  out.reserve(s.size());
  for (const unsigned char c : s) {
    // Explicit ASCII, not locale-sensitive isalnum, to match Ruby's fixed class.
    if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
        c == '-' || c == '_' || c == '.' || c == '~') {
      out += c;
    } else {
      out += '%';
      out += hex[c >> 4];
      out += hex[c & 0x0F];
    }
  }
  return out;
}

inline std::string ascii_lower(const std::string_view s) {
  std::string out(s);
  for (char& c : out) {
    if (c >= 'A' && c <= 'Z') c += 32;
  }
  return out;
}

// The `#`-prefixed hex color keeps its leading byte literal and percent-escapes
// the rest, matching the parser side.
inline std::string color_value(const std::string& color) {
  if (color.starts_with('#')) {
    return "#" + uri_escape(std::string_view(color).substr(1));
  }
  return uri_escape(color);
}

// lib/dtext/renderer.rb lists the same values for each id link, split across
// three tables.
struct IdMeta {
  std::string display;
  std::string route;
  std::string infix;
};

inline const std::unordered_map<std::string, IdMeta> ID_META = {
  {"post", {"post", "/posts/", "post"}},
  {"post_changes", {"post changes", "/post_versions?search[post_id]=", "post-changes-for"}},
  {"flag", {"flag", "/post_flags/", "post-flag"}},
  {"note", {"note", "/notes/", "note"}},
  {"forum_post", {"forum", "/forum_posts/", "forum-post"}},
  {"topic", {"topic", "/forum_topics/", "forum-topic"}},
  {"comment", {"comment", "/comments/", "comment"}},
  {"pool", {"pool", "/pools/", "pool"}},
  {"user", {"user", "/users/", "user"}},
  {"artist", {"artist", "/artists/", "artist"}},
  {"ban", {"ban", "/bans/", "ban"}},
  {"bur", {"BUR", "/bulk_update_requests/", "bulk-update-request"}},
  {"alias", {"alias", "/tag_aliases/", "tag-alias"}},
  {"implication", {"implication", "/tag_implications/", "tag-implication"}},
  {"mod_action", {"mod action", "/mod_actions/", "mod-action"}},
  {"record", {"record", "/user_feedbacks/", "user-feedback"}},
  {"wiki", {"wiki", "/wiki_pages/", "wiki-page"}},
  {"set", {"set", "/post_sets/", "set"}},
  {"blip", {"blip", "/blips/", "blip"}},
  {"ticket", {"ticket", "/tickets/", "ticket"}},
  {"appeal", {"appeal", "/appeals/", "appeal"}},
  {"takedown", {"takedown", "/takedowns/", "takedown"}},
};

inline const IdMeta& id_meta(const std::string& key) {
  static const IdMeta empty;
  auto found = ID_META.find(key);
  return found == ID_META.end() ? empty : found->second;
}

}  // namespace html_sink_detail

// Each container opens and closes as its tag, absent in inline mode for a block
// element. Closing a paragraph trims the output, see close_paragraph.
class HtmlSink : public sink::Sink {
public:
  explicit HtmlSink(const render::Options& options) : options(options) {}

  // INLINE_COLOR and BLOCK_SECTION are absent from this switch on purpose: the
  // parser opens them through open_color / open_section (they carry attributes),
  // never through open(). Adding cases here would double-emit their tags.
  void open(element_t element) override {
    if (is_block_element(element) && options.f_inline) return;

    switch (element) {
      case BLOCK_P: out += "<p>"; break;
      case BLOCK_QUOTE: out += "<blockquote>"; break;
      case BLOCK_SPOILER: out += "<div class=\"spoiler\">"; break;
      case BLOCK_CODE: out += "<pre>"; break;
      case BLOCK_TABLE: out += "<table class=\"striped\">"; break;
      case BLOCK_THEAD: out += "<thead>"; break;
      case BLOCK_TBODY: out += "<tbody>"; break;
      case BLOCK_UL: out += "<ul>"; break;
      case BLOCK_LI: out += "<li>"; break;
      case BLOCK_TR: out += "<tr>"; break;
      case BLOCK_TH: out += "<th>"; break;
      case BLOCK_TD: out += "<td>"; break;
      case BLOCK_H1: case BLOCK_H2: case BLOCK_H3:
      case BLOCK_H4: case BLOCK_H5: case BLOCK_H6:
        out += "<h"; out += static_cast<char>('1' + (element - BLOCK_H1)); out += ">"; break;
      case INLINE_B: out += "<strong>"; break;
      case INLINE_I: out += "<em>"; break;
      case INLINE_U: out += "<u>"; break;
      case INLINE_S: out += "<s>"; break;
      case INLINE_SUP: out += "<sup>"; break;
      case INLINE_SUB: out += "<sub>"; break;
      case INLINE_SPOILER: out += "<span class=\"spoiler\">"; break;
      case INLINE_CODE: out += "<span class=\"inline-code\">"; break;
      default: break;
    }
  }

  void open_quote(const std::string* color, bool category) override {
    if (options.f_inline) return;
    if (color == nullptr) {
      out += "<blockquote>";
    } else if (category) {
      out += "<blockquote class=\"dtext-sidebar-colored-" + html_sink_detail::uri_escape(*color) + "\">";
    } else {
      out += "<blockquote class=\"dtext-quote-color\" style=\"border-left-color:" + html_sink_detail::color_value(*color) + "\">";
    }
  }

  void open_color(std::string_view color, bool category) override {
    std::string value(color);
    if (category) {
      out += "<span class=\"dtext-color-" + html_sink_detail::uri_escape(value) + "\">";
    } else {
      out += "<span class=\"dtext-color\" style=\"color:" + html_sink_detail::color_value(value) + "\">";
    }
  }

  void open_section(const std::string* title, bool expanded) override {
    if (options.f_inline) {
      if (title != nullptr) out += html_sink_detail::html_escape(*title);
      return;
    }
    out += expanded ? "<details open><summary>" : "<details><summary>";
    if (title != nullptr) out += html_sink_detail::html_escape(*title);
    out += "</summary><div>";
  }

  void close(element_t element) override {
    if (element == BLOCK_P) {
      close_paragraph();
      return;
    }
    if (is_block_element(element) && options.f_inline) return;

    switch (element) {
      case BLOCK_QUOTE: out += "</blockquote>"; break;
      case BLOCK_SPOILER: out += "</div>"; break;
      case BLOCK_SECTION: out += "</div></details>"; break;
      case BLOCK_CODE: out += "</pre>"; break;
      case BLOCK_TABLE: out += "</table>"; break;
      case BLOCK_THEAD: out += "</thead>"; break;
      case BLOCK_TBODY: out += "</tbody>"; break;
      case BLOCK_UL: out += "</ul>"; break;
      case BLOCK_LI: out += "</li>"; break;
      case BLOCK_TR: out += "</tr>"; break;
      case BLOCK_TH: out += "</th>"; break;
      case BLOCK_TD: out += "</td>"; break;
      case BLOCK_H1: case BLOCK_H2: case BLOCK_H3:
      case BLOCK_H4: case BLOCK_H5: case BLOCK_H6:
        out += "</h"; out += static_cast<char>('1' + (element - BLOCK_H1)); out += ">"; break;
      case INLINE_B: out += "</strong>"; break;
      case INLINE_I: out += "</em>"; break;
      case INLINE_U: out += "</u>"; break;
      case INLINE_S: out += "</s>"; break;
      case INLINE_SUP: out += "</sup>"; break;
      case INLINE_SUB: out += "</sub>"; break;
      case INLINE_COLOR: out += "</span>"; break;
      case INLINE_SPOILER: out += "</span>"; break;
      case INLINE_CODE: out += "</span>"; break;
      default: break;
    }
  }

  void text(std::string_view text) override { html_sink_detail::escape_into(out, text); }
  void content(std::string_view content) override { html_sink_detail::escape_into(out, content); }
  void line_break() override { out += "<br>"; }
  void raw_block(std::string_view text) override { if (!options.f_inline) out += text; }

  // The grammar allows only digits in an id, so the href and the text need no
  // escaping.
  void id_link(std::string_view id_type, std::string_view id) override {
    if (id_type == "thumb" && thumb_count < options.max_thumbs) {
      thumb_count++;
      long value = 0;
      std::from_chars(id.data(), id.data() + id.size(), value);
      post_ids.push_back(value);
      out += "<a class=\"dtext-link dtext-id-link dtext-post-id-link thumb-placeholder-link\" data-id=\"";
      out += id;
      out += "\" href=\"";
      if (!options.base_url.empty()) out += options.base_url;
      out += "/posts/";
      out += id;
      out += "\">post #";
      out += id;
      out += "</a>";
    } else {
      std::string type = id_type == "thumb" ? "post" : std::string(id_type);
      const html_sink_detail::IdMeta& meta = html_sink_detail::id_meta(type);
      out += "<a class=\"dtext-link dtext-id-link dtext-";
      out += meta.infix;
      out += "-id-link\" href=\"";
      if (!options.base_url.empty() && meta.route.starts_with('/')) out += options.base_url;
      out += meta.route;
      out += id;
      out += "\">";
      out += meta.display;
      out += " #";
      out += id;
      out += "</a>";
    }
  }

  void unnamed_url(std::string_view href) override {
    out += "<a rel=\"nofollow\" class=\"dtext-link\" href=\"";
    html_sink_detail::escape_into(out, href);
    out += "\">";
    html_sink_detail::escape_into(out, href);
    out += "</a>";
  }

  void named_url(std::string_view href, std::vector<ast::Node>&& title) override {
    bool internal = href.starts_with('/') || href.starts_with('#');
    out += internal ? "<a rel=\"nofollow\" class=\"dtext-link\" href=\""
                    : "<a rel=\"nofollow\" class=\"dtext-link dtext-external-link\" href=\"";
    if (internal && !options.base_url.empty()) out += options.base_url;
    html_sink_detail::escape_into(out, href);
    out += "\">";
    render_children(title);
    out += "</a>";
  }

  void wiki_link(std::string_view href, std::string_view title) override {
    out += "<a rel=\"nofollow\" class=\"dtext-link dtext-wiki-link\" href=\"";
    if (!options.base_url.empty() && href.starts_with('/')) out += options.base_url;
    html_sink_detail::escape_into(out, href);
    out += "\">";
    html_sink_detail::escape_into(out, title);
    out += "</a>";
  }

  void post_search_link(std::string_view href, std::string_view title) override {
    out += "<a rel=\"nofollow\" class=\"dtext-link dtext-post-search-link\" href=\"";
    if (!options.base_url.empty() && href.starts_with('/')) out += options.base_url;
    html_sink_detail::escape_into(out, href);
    out += "\">";
    html_sink_detail::escape_into(out, title);
    out += "</a>";
  }

  void internal_anchor(std::string_view name) override {
    out += "<a id=\"";
    out += html_sink_detail::uri_escape(html_sink_detail::ascii_lower(std::string(name)));
    out += "\"></a>";
  }

  render::Result take_result() {
    return { std::move(out), std::move(post_ids) };
  }

  std::string out;

private:
  // Drops one trailing <br>, then drops an empty <p> without a </p>, or closes
  // it.
  void close_paragraph() {
    if (out.size() > 4 && out.ends_with("<br>")) out.resize(out.size() - 4);
    if (options.f_inline) return;

    if (out.size() > 3 && out.ends_with("<p>")) {
      out.resize(out.size() - 3);
    } else {
      out += "</p>";
    }
  }

  // A named link's title is the inline nodes the basic-inline grammar produces
  // (dtext.cpp.rl `basic_inline`): text plus the six formatting wrappers below,
  // nothing else. This chain must cover that whole vocabulary. If the grammar
  // ever emits a new inline type, add it here AND in the Ruby renderer, which
  // raises on an unknown type where this would silently drop it.
  void render_children(const std::vector<ast::Node>& children) {
    namespace NT = ast::NodeType;
    for (const ast::Node& child : children) {
      if (child.type == NT::TEXT) {
        html_sink_detail::escape_into(out, child.content);
      } else if (child.type == NT::BOLD) {
        out += "<strong>"; render_children(child.children); out += "</strong>";
      } else if (child.type == NT::ITALIC) {
        out += "<em>"; render_children(child.children); out += "</em>";
      } else if (child.type == NT::STRIKEOUT) {
        out += "<s>"; render_children(child.children); out += "</s>";
      } else if (child.type == NT::UNDERLINE) {
        out += "<u>"; render_children(child.children); out += "</u>";
      } else if (child.type == NT::SUPERSCRIPT) {
        out += "<sup>"; render_children(child.children); out += "</sup>";
      } else if (child.type == NT::SUBSCRIPT) {
        out += "<sub>"; render_children(child.children); out += "</sub>";
      }
    }
  }

  // Held by value so an HtmlSink can outlive the Options the caller passed.
  render::Options options;
  int thumb_count = 0;
  std::vector<long> post_ids;
};

#endif
