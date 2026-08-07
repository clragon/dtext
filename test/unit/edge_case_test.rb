require 'minitest/autorun'
require 'dtext'
require_relative 'test_helper'

class DTextEdgeCaseTest < Minitest::Test
  include DTextTestHelper

  def test_quote_close_does_not_swallow_following_text
    assert_parse("<blockquote><p>hi</p></blockquote><p>after</p>", "[quote]hi[/quote] after")
  end

  # A block open ([code]) inside an inline run exits the paragraph, closing the
  # open inline; the tail after the block reopens a paragraph and the now-stray
  # [/b] survives as literal text.
  def test_block_open_exits_open_inline
    assert_parse("<p><strong>a </strong></p><pre>x</pre><p> b[/b]</p>", "[b]a [code]x[/code] b[/b]")
  end

  # The trailing <br> lives inside the still-open <strong>, so it is not the
  # paragraph's last output and the closing-paragraph trim leaves it alone.
  def test_trailing_break_inside_inline_survives
    assert_parse("<p><strong><br>body<br></strong></p>", "[b]\nbody\n[/b]")
  end

  def test_header_ends_at_newline_then_paragraph
    assert_parse("<h1>head</h1><p><strong>bold</strong></p>", "h1. head\n[b]bold")
  end

  def test_stray_inline_close_is_literal
    assert_parse(
      "<p><a class=\"dtext-link dtext-id-link dtext-post-id-link\" href=\"/posts/1\">post #1</a> [/b] " \
      "<a class=\"dtext-link dtext-id-link dtext-post-id-link thumb-placeholder-link\" data-id=\"2\" " \
      "href=\"/posts/2\">post #2</a></p>",
      "post #1 [/b] thumb #2",
    )
  end

  def test_paragraph_break_closes_list
    assert_parse("<ul><li>a</li><li>b</li></ul><p>after</p>", "* a\n* b\n\nafter")
  end

  # With color allowed, an unclosed-across-break color holds the paragraph open,
  # so the two halves merge into one span (the paragraph break is consumed).
  def test_color_holds_paragraph_across_break
    assert_parse(
      "<p><span class=\"dtext-color\" style=\"color:red\">xy</span></p>",
      "[color=red]x\n\ny[/color]",
      allow_color: true,
    )
  end

  # Without color allowed, the color tags vanish and the paragraph break splits
  # the text normally.
  def test_color_disallowed_lets_paragraph_break
    assert_parse("<p>x</p><p>y</p>", "[color=red]x\n\ny[/color]", allow_color: false)
  end
end
