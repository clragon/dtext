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

    str = preprocess_for_tables(str)
    c_render(str, allow_color, inline, max_thumbs, base_url)
  end

  # `allow_color` changes block nesting around unclosed colors, so the parser
  # takes it rather than the renderer. Returns nil for nil input.
  def self.parse_to_ast(str, allow_color: false)
    return nil if str.nil?
    raise TypeError unless str.respond_to?(:gsub)

    str = preprocess_for_tables(str)
    c_parse(str, allow_color)
  end

  private

  def self.preprocess_for_tables(str)
    str.gsub(/(?:\[ltable\])(.*?)(?:\[\/ltable\]|\z)/mi) do
      contents = Regexp.last_match[1].strip
      row_num = 0
      rows = contents.split(/\n/).map do |row|
        cols = row.split(/(?<!\\)\|/).map do |col|
          row_num == 0 ? "[th]#{col}[/th]" : "[td]#{col}[/td]"
        end
        new_row = row_num == 0 ? "[thead][tr]#{cols.join('')}[/tr][/thead][tbody]" : "[tr]#{cols.join('')}[/tr]"
        row_num += 1
        new_row
      end
      "[table]#{rows.join('')}[/tbody][/table]"
    end
  rescue ArgumentError => e
    raise Error.new(e.message)
  end
end
