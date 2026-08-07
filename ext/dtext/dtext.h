#ifndef DTEXT_H
#define DTEXT_H

#include <string>
#include <string_view>
#include <vector>
#include <stdexcept>

#include "ast.h"
#include "element.h"

class DTextError : public std::runtime_error {
  using std::runtime_error::runtime_error;
};

// The parser tracks structure in the dstack and calls its sink for each element
// it recognizes. The sink is a template parameter, so the calls stay direct and
// inline.
template <class SinkT>
class StateMachine {
public:
  StateMachine(std::string_view dtext, int initial_state, bool allow_color, SinkT& sink);
  void run();

private:
  void append_text(std::string_view text);
  void append_text(char c);
  void append_content(std::string_view text);
  void append_content(char c);

  void append_line_break();
  void append_raw_block(std::string_view text);
  void append_section(std::string_view summary, bool initially_open);

  // Link emits that need parse-side work before handing typed pieces to the
  // sink: a title parsed as basic-inline, or an href normalized and escaped.
  void emit_named_url(std::string_view url, std::string_view title);
  void emit_wiki_link(std::string_view tag, std::string_view title);
  void emit_post_search_link(std::string_view tag, std::string_view title);

  void dstack_open_block(element_t type);
  void dstack_open_inline(element_t type);
  void open_colored_quote(std::string_view color, bool category);
  void open_colored_span(std::string_view color, bool category);
  void dstack_open_list(int depth);

  void dstack_close_inline(element_t type);
  bool dstack_close_block(element_t type);
  void dstack_close_before_block();
  void dstack_close_leaf_blocks();
  void dstack_close_until(element_t element);
  void dstack_close_all();
  void dstack_close_list();
  void dstack_rewind();

  void dstack_push(element_t element);
  bool dstack_is_open(element_t element);
  bool dstack_check(element_t expected_element);
  int dstack_count(element_t element);
  element_t dstack_peek();

  SinkT& sink;
  bool allow_color = false;

  size_t top_state;
  int cs;
  int act = 0;
  const char * p = NULL;
  const char * pb = NULL;
  const char * pe = NULL;
  const char * eof = NULL;
  const char * ts = NULL;
  const char * te = NULL;
  const char * a1 = NULL;
  const char * a2 = NULL;
  const char * b1 = NULL;
  const char * b2 = NULL;

  bool header_mode = false;
  int ignored_sup_sub_tags = 0;

  std::vector<int> stack;
  std::vector<element_t> dstack;
};

// Entry points, defined where the ragel tables and both sinks are visible.
// `parse_to_ast` builds the AST; the HTML entry is render::to_html.
ast::Node parse_to_ast(std::string_view dtext, bool allow_color);
// Parse a link title through the restricted basic-inline grammar. Used by the
// textile-link builders, which run a nested parse into a tree.
std::vector<ast::Node> parse_basic_inline(std::string_view dtext);

#endif
