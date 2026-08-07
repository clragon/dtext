#ifndef DTEXT_TREE_SINK_H
#define DTEXT_TREE_SINK_H

#include <vector>

#include "ast.h"
#include "sink.h"

// The sink that builds the AST. It keeps a stack of open container nodes
// (document at the base) and attaches each finished node to its parent on
// close, so the tree mirrors the parser's dstack. Unlike the HTML sink it
// applies no output fixups. Empty paragraphs and trailing line breaks stay in
// the tree, and the renderer drops them.
namespace sink {

class TreeSink : public Sink {
public:
  TreeSink();

  void open(element_t element) override;
  void open_quote(const std::string* color, bool category) override;
  void open_color(std::string_view color, bool category) override;
  void open_section(const std::string* title, bool expanded) override;
  void close(element_t element) override;
  void text(std::string_view text) override;
  void content(std::string_view content) override;
  void line_break() override;
  void raw_block(std::string_view text) override;
  void id_link(std::string_view id_type, std::string_view id) override;
  void unnamed_url(std::string_view href) override;
  void named_url(std::string_view href, std::vector<ast::Node>&& title) override;
  void wiki_link(std::string_view href, std::string_view title) override;
  void post_search_link(std::string_view href, std::string_view title) override;
  void internal_anchor(std::string_view name) override;

  // The finished document. Valid once the parse has run to completion.
  ast::Node take_document();

private:
  ast::Node& current();
  void push(ast::Node node);

  std::vector<ast::Node> ostack;
};

}  // namespace sink

#endif
