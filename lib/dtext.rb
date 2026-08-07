require "dtext/dtext"
require "dtext/version"
require "dtext/renderer"

class DText
  class Error < StandardError; end

  # Returns `[html, post_ids]`. Renders in C++ through `c_render`, without
  # building a tree.
  def self.parse(str, inline: false, allow_color: false, max_thumbs: 25, base_url: nil)
    return nil if str.nil?
    raise TypeError unless str.respond_to?(:gsub)
    raise Error, "invalid byte sequence in UTF-8" unless str.valid_encoding?

    c_render(str, allow_color, inline, max_thumbs, base_url)
  end

  # `allow_color` changes block nesting around unclosed colors, so the parser
  # takes it rather than the renderer. Returns nil for nil input.
  def self.parse_to_ast(str, allow_color: false)
    return nil if str.nil?
    raise TypeError unless str.respond_to?(:gsub)
    raise Error, "invalid byte sequence in UTF-8" unless str.valid_encoding?

    c_parse(str, allow_color)
  end
end
