#ifndef DTEXT_SINK_H
#define DTEXT_SINK_H

#include <string>
#include <string_view>

#include "ast.h"
#include "element.h"

// The state machine calls these methods as it recognizes markup. TreeSink
// builds the AST and HtmlSink writes HTML. Text and code bodies arrive as whole
// strings rather than single bytes.
namespace sink {

struct Sink {
  virtual ~Sink() = default;

  // Open an element whose attributes are fixed by the element itself (header
  // level, table-cell kind) or that carries none.
  virtual void open(element_t element) = 0;
  // Open a quote. `color` is null for a plain quote; otherwise `category`
  // distinguishes a tag-category name from a free color value.
  virtual void open_quote(const std::string* color, bool category) = 0;
  virtual void open_color(std::string_view color, bool category) = 0;
  // Open a section. `title` is null when the source gave no summary text.
  virtual void open_section(const std::string* title, bool expanded) = 0;
  virtual void close(element_t element) = 0;

  virtual void text(std::string_view text) = 0;
  // A code or inline-code body, verbatim source the renderer escapes once.
  virtual void content(std::string_view content) = 0;
  virtual void line_break() = 0;
  // A stray block-level close with no matching open, streamed as literal.
  virtual void raw_block(std::string_view text) = 0;

  // Links arrive as typed events with their pieces already resolved, not as a
  // built node, so the HTML sink can render straight to its buffer without
  // allocating a node it would only read once and discard.
  virtual void id_link(std::string_view id_type, std::string_view id) = 0;
  virtual void unnamed_url(std::string_view href) = 0;
  virtual void named_url(std::string_view href, std::vector<ast::Node>&& title) = 0;
  virtual void wiki_link(std::string_view href, std::string_view title) = 0;
  virtual void post_search_link(std::string_view href, std::string_view title) = 0;
  virtual void internal_anchor(std::string_view name) = 0;
};

}  // namespace sink

#endif
