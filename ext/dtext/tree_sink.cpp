#include "tree_sink.h"

using ast::Node;
namespace NT = ast::NodeType;
namespace A = ast::Attr;

namespace {

// The node type a given open element maps to. This is the one place the two
// vocabularies (dstack elements, AST node types) meet.
const char* node_type_for(element_t element) {
  switch (element) {
    case BLOCK_P: return NT::PARAGRAPH;
    case BLOCK_QUOTE: return NT::QUOTE;
    case BLOCK_SECTION: return NT::SECTION;
    case BLOCK_SPOILER: return NT::SPOILER_BLOCK;
    case BLOCK_CODE: return NT::CODE_BLOCK;
    case BLOCK_TABLE: return NT::TABLE;
    case BLOCK_THEAD: return NT::TABLE_HEAD;
    case BLOCK_TBODY: return NT::TABLE_BODY;
    case BLOCK_UL: return NT::LIST;
    case BLOCK_LI: return NT::LIST_ITEM;
    case BLOCK_TR: return NT::TABLE_ROW;
    case BLOCK_TH: return NT::TABLE_CELL;
    case BLOCK_TD: return NT::TABLE_CELL;
    case BLOCK_H1: case BLOCK_H2: case BLOCK_H3:
    case BLOCK_H4: case BLOCK_H5: case BLOCK_H6: return NT::HEADER;
    case INLINE_B: return NT::BOLD;
    case INLINE_I: return NT::ITALIC;
    case INLINE_U: return NT::UNDERLINE;
    case INLINE_S: return NT::STRIKEOUT;
    case INLINE_SUP: return NT::SUPERSCRIPT;
    case INLINE_SUB: return NT::SUBSCRIPT;
    case INLINE_COLOR: return NT::COLOR;
    case INLINE_SPOILER: return NT::INLINE_SPOILER;
    case INLINE_CODE: return NT::INLINE_CODE;
    case DSTACK_EMPTY: return NT::TEXT;
  }
  return NT::TEXT;
}

}  // namespace

namespace sink {

TreeSink::TreeSink() {
  ostack.reserve(16);
  ostack.emplace_back(NT::DOCUMENT);
}

ast::Node& TreeSink::current() {
  return ostack.back();
}

void TreeSink::push(ast::Node node) {
  ostack.push_back(std::move(node));
}

void TreeSink::open(element_t element) {
  push(Node(node_type_for(element)));

  if (element >= BLOCK_H1 && element <= BLOCK_H6) {
    current().set(A::LEVEL, (long)(element - BLOCK_H1 + 1));
  } else if (element == BLOCK_TH) {
    current().set(A::CELL_TYPE, std::string("th"));
  } else if (element == BLOCK_TD) {
    current().set(A::CELL_TYPE, std::string("td"));
  }
}

void TreeSink::open_quote(const std::string* color, bool category) {
  push(Node(NT::QUOTE));
  if (color != nullptr) {
    current().set(A::COLOR, *color);
    current().set(A::CATEGORY, category);
  }
}

void TreeSink::open_color(std::string_view color, bool category) {
  push(Node(NT::COLOR));
  current().set(A::COLOR, std::string(color));
  current().set(A::CATEGORY, category);
}

void TreeSink::open_section(const std::string* title, bool expanded) {
  push(Node(NT::SECTION));
  if (expanded) {
    current().set(A::EXPANDED, true);
  }
  if (title != nullptr) {
    current().set(A::TITLE, *title);
  }
}

void TreeSink::close(element_t element) {
  (void)element;
  Node node = std::move(ostack.back());
  ostack.pop_back();
  ostack.back().children.push_back(std::move(node));
}

void TreeSink::text(std::string_view text) {
  auto& children = current().children;
  if (!children.empty() && children.back().type == NT::TEXT) {
    children.back().content.append(text);
  } else {
    Node node(NT::TEXT);
    node.content = std::string(text);
    children.push_back(std::move(node));
  }
}

void TreeSink::content(std::string_view content) {
  current().content.append(content);
}

void TreeSink::line_break() {
  current().children.emplace_back(NT::LINE_BREAK);
}

void TreeSink::raw_block(std::string_view text) {
  Node node(NT::RAW_BLOCK_TEXT);
  node.content = std::string(text);
  current().children.push_back(std::move(node));
}

void TreeSink::id_link(std::string_view id_type, std::string_view id) {
  Node n(NT::LINK);
  n.attrs.reserve(3);
  n.set(A::LINK_TYPE, std::string("id_link"));
  n.set(A::ID_TYPE, std::string(id_type));
  n.set(A::ID, std::string(id));
  current().children.push_back(std::move(n));
}

void TreeSink::unnamed_url(std::string_view href) {
  Node n(NT::LINK);
  n.set(A::LINK_TYPE, std::string("url"));
  n.set(A::HREF, std::string(href));
  current().children.push_back(std::move(n));
}

void TreeSink::named_url(std::string_view href, std::vector<ast::Node>&& title) {
  Node n(NT::LINK);
  n.set(A::LINK_TYPE, std::string("inline"));
  n.set(A::HREF, std::string(href));
  n.children = std::move(title);
  current().children.push_back(std::move(n));
}

void TreeSink::wiki_link(std::string_view href, std::string_view title) {
  Node n(NT::LINK);
  n.set(A::LINK_TYPE, std::string("wiki"));
  n.set(A::HREF, std::string(href));
  Node t(NT::TEXT);
  t.content = std::string(title);
  n.children.push_back(std::move(t));
  current().children.push_back(std::move(n));
}

void TreeSink::post_search_link(std::string_view href, std::string_view title) {
  Node n(NT::LINK);
  n.set(A::LINK_TYPE, std::string("post_search"));
  n.set(A::HREF, std::string(href));
  Node t(NT::TEXT);
  t.content = std::string(title);
  n.children.push_back(std::move(t));
  current().children.push_back(std::move(n));
}

void TreeSink::internal_anchor(std::string_view name) {
  Node n(NT::INTERNAL_ANCHOR);
  n.set(A::NAME, std::string(name));
  current().children.push_back(std::move(n));
}

ast::Node TreeSink::take_document() {
  return std::move(ostack.front());
}

}  // namespace sink
