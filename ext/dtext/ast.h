#ifndef DTEXT_AST_H
#define DTEXT_AST_H

#include <string>
#include <variant>
#include <vector>

// `children` lists the nodes inside a node, `content` is its text, and `attrs`
// is a list of keys, each with a typed value. node_to_ruby (rb_dtext.cpp) turns
// a node into `{ type:, children:, <content>, <attrs...> }`.
//
// Each `type` is one of the string literals below, so two types compare by
// pointer.
namespace ast {

// Node type tags. Each is a string literal so it doubles as the Ruby hash's
// `type` value with no per-node allocation. Grouped block / inline / table the
// same way dtext.h groups element_t, since the parser maps one onto the other.
namespace NodeType {
inline constexpr const char* DOCUMENT = "document";

inline constexpr const char* HEADER = "header";
inline constexpr const char* PARAGRAPH = "paragraph";
inline constexpr const char* QUOTE = "quote";
inline constexpr const char* SPOILER_BLOCK = "spoiler_block";
inline constexpr const char* SECTION = "section";
inline constexpr const char* CODE_BLOCK = "code_block";
inline constexpr const char* TABLE = "table";
// expand_ltable (dtext.cpp.rl) turns an [ltable] body into [table] markup
// during the parse, so the AST has no ltable node.
inline constexpr const char* LIST = "list";
inline constexpr const char* LIST_ITEM = "list_item";

// A stray block-level closing tag with no matching open (`[/table]`, `[/tr]`,
// and the like). It is absent in inline mode and emitted word for word
// otherwise. The renderer emits `content` unescaped, which is safe because the
// content is a literal close tag with no HTML-special bytes.
inline constexpr const char* RAW_BLOCK_TEXT = "raw_block_text";

inline constexpr const char* TABLE_HEAD = "table_head";
inline constexpr const char* TABLE_BODY = "table_body";
inline constexpr const char* TABLE_ROW = "table_row";
inline constexpr const char* TABLE_CELL = "table_cell";

inline constexpr const char* TEXT = "text";
inline constexpr const char* BOLD = "bold";
inline constexpr const char* ITALIC = "italic";
inline constexpr const char* STRIKEOUT = "strikeout";
inline constexpr const char* UNDERLINE = "underline";
inline constexpr const char* SUPERSCRIPT = "superscript";
inline constexpr const char* SUBSCRIPT = "subscript";
inline constexpr const char* INLINE_SPOILER = "inline_spoiler";
inline constexpr const char* INLINE_CODE = "inline_code";
inline constexpr const char* COLOR = "color";
inline constexpr const char* LINK = "link";
inline constexpr const char* INTERNAL_ANCHOR = "internal_anchor";
inline constexpr const char* LINE_BREAK = "line_break";
}  // namespace NodeType

// Attribute keys. Interned the same way as type tags so the Ruby hash keys
// cost nothing to build.
namespace Attr {
inline constexpr const char* CONTENT = "content";
inline constexpr const char* LEVEL = "level";
inline constexpr const char* COLOR = "color";
inline constexpr const char* HREF = "href";
inline constexpr const char* TITLE = "title";
inline constexpr const char* LINK_TYPE = "link_type";
inline constexpr const char* ID_TYPE = "id_type";
inline constexpr const char* ID = "id";
inline constexpr const char* ANCHOR = "anchor";
inline constexpr const char* TAGS = "tags";
inline constexpr const char* NAME = "name";
inline constexpr const char* CELL_TYPE = "cell_type";
inline constexpr const char* DEPTH = "depth";
inline constexpr const char* EXPANDED = "expanded";
inline constexpr const char* WRAPPER = "wrapper";
inline constexpr const char* SOURCE = "source";
// True when a color token matched the grammar's `color_name` (a tag category
// or user group) rather than a free `color_value`. The parser decides this
// from the grammar, so the renderer picks the class-name form over the inline-
// style form without re-deriving the category set (which the grammar and any
// renderer-side regex would otherwise have to keep in lockstep).
inline constexpr const char* CATEGORY = "category";
}  // namespace Attr

// An attribute value. `long` covers header level and list depth, `bool` covers
// the section's expanded flag, `std::string` covers every identifier-ish
// field. The variant order fixes how the boundary maps each to a Ruby type.
using AttrValue = std::variant<std::string, long, bool>;

struct Node {
  const char* type;
  // The text of a text, inline_code, code_block, raw_block_text or
  // table_literal node. Empty on every other node.
  std::string content;
  std::vector<Node> children;
  // Structured extras keyed by Attr::*. Kept off the hot text-node path so a
  // plain text node stays two allocations (the node and its content).
  std::vector<std::pair<const char*, AttrValue>> attrs;

  explicit Node(const char* type) : type(type) {}

  Node& set(const char* key, AttrValue value) {
    attrs.emplace_back(key, std::move(value));
    return *this;
  }
};

}  // namespace ast

#endif
