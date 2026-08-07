require 'minitest/autorun'
require 'dtext'
require_relative 'test_helper'

class DTextRendererTest < Minitest::Test
  def render(input, **options)
    ast = DText.parse_to_ast(input, allow_color: options.fetch(:allow_color, false))
    DText::Renderer.render(
      ast,
      inline: options.fetch(:inline, false),
      max_thumbs: options.fetch(:max_thumbs, 25),
      base_url: options[:base_url],
    ).first
  end

  # Every input the native path renders one way, the Ruby renderer must render
  # the same way, across the option axes that change output.
  def assert_renderers_agree(input, **options)
    native = DText.parse(input, **options).first
    ruby = render(input, **options)
    assert_equal(native, ruby, "renderers diverged on #{input.inspect} #{options.inspect}")
  end

  def test_renders_core_markup
    assert_equal("<p><strong>a</strong></p>", render("[b]a[/b]"))
    assert_equal("<h1>x</h1>", render("h1. x"))
    assert_equal("<blockquote><p>q</p></blockquote>", render("[quote]q[/quote]"))
    assert_equal("<pre>a &lt; b</pre>", render("[code]a < b[/code]"))
  end

  def test_inline_option_suppresses_block_wrappers
    assert_equal("a", render("a", inline: true))
    assert_equal("q", render("[quote]q[/quote]", inline: true))
  end

  def test_thumbnail_budget_and_post_ids
    ast = DText.parse_to_ast("thumb #1 thumb #2 thumb #3")
    _html, posts = DText::Renderer.render(ast, inline: false, max_thumbs: 2, base_url: nil)
    # Only the first two thumbnails stay placeholders and reach post_ids; the
    # third falls back to a plain post link.
    assert_equal([1, 2], posts)
  end

  def test_base_url_prefixes_internal_hrefs
    html = render("post #5", base_url: "https://e621.net")
    assert_includes(html, 'href="https://e621.net/posts/5"')
  end

  def test_color_gating_matches_native
    assert_renderers_agree("[color=red]c[/color]", allow_color: false)
    assert_renderers_agree("[color=red]c[/color]", allow_color: true)
  end

  def test_renderers_agree_across_options
    inputs = [
      "h1. Head\n\n[b]bold[/b] and post #7",
      "[quote=art]side[/quote]",
      "* a\n** b\n* c",
      %q{see "here":https://example.com/x?y=1&z=2 now},
      "[[Foo|bar]] and {{tag_a tag_b}}",
      "thumb #10 thumb #20",
      "[section=Notes]hidden[/section]",
    ]
    options = [
      {},
      { inline: true },
      { allow_color: true },
      { max_thumbs: 1 },
      { base_url: "https://e621.net" },
    ]

    inputs.each do |input|
      options.each { |opts| assert_renderers_agree(input, **opts) }
    end
  end
end
