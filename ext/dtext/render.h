#ifndef DTEXT_RENDER_H
#define DTEXT_RENDER_H

#include <string>
#include <string_view>
#include <vector>

#include "ast.h"

// `to_html` parses and writes HTML in one pass through HtmlSink, without
// building a tree. lib/dtext/renderer.rb renders the AST from `parse_to_ast`.
namespace render {

struct Options {
  bool f_inline = false;
  int max_thumbs = 25;
  std::string base_url;
};

struct Result {
  std::string html;
  // Ids of the thumbnails that render as placeholders, in order. max_thumbs
  // caps how many.
  std::vector<long> post_ids;
};

Result to_html(std::string_view dtext, bool allow_color, const Options& options);

}  // namespace render

#endif
