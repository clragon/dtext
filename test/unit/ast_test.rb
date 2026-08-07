require 'minitest/autorun'
require 'dtext'
require_relative 'test_helper'

class DTextAstTest < Minitest::Test
  def assert_ast(expected, input, **options)
    assert_equal(expected, DText.parse_to_ast(input, **options))
  end

  def doc(*children)
    { type: :document, children: children }
  end

  def test_plain_text_wraps_in_a_paragraph
    assert_ast(
      doc({ type: :paragraph, children: [{ type: :text, content: "hi" }] }),
      "hi",
    )
  end

  def test_inline_formatting_nests
    assert_ast(
      doc({ type: :paragraph, children: [
        { type: :bold, children: [{ type: :text, content: "a" }] },
        { type: :italic, children: [{ type: :text, content: "b" }] },
      ] }),
      "[b]a[/b][i]b[/i]",
    )
  end

  def test_header_carries_level
    assert_ast(
      doc({ type: :header, level: 2, children: [{ type: :text, content: "Title" }] }),
      "h2. Title",
    )
  end

  def test_plain_quote
    assert_ast(
      doc({ type: :quote, children: [
        { type: :paragraph, children: [{ type: :text, content: "q" }] },
      ] }),
      "[quote]q[/quote]",
    )
  end

  def test_category_quote_records_color_and_category
    assert_ast(
      doc({ type: :quote, color: "art", category: true, children: [
        { type: :paragraph, children: [{ type: :text, content: "q" }] },
      ] }),
      "[quote=art]q[/quote]",
    )
  end

  def test_value_quote_is_not_a_category
    assert_ast(
      doc({ type: :quote, color: "red", category: false, children: [
        { type: :paragraph, children: [{ type: :text, content: "q" }] },
      ] }),
      "[quote=red]q[/quote]",
    )
  end

  def test_section_records_title_and_expanded
    assert_ast(
      doc({ type: :section, expanded: true, title: "Summary", children: [
        { type: :paragraph, children: [{ type: :text, content: "body" }] },
      ] }),
      "[section,expanded=Summary]body[/section]",
    )
  end

  def test_id_link_carries_type_and_id_but_no_href
    # The renderer derives href/display/classes from id_type; the parser stores
    # only the semantic pair, so the id-link vocabulary lives in one place.
    assert_ast(
      doc({ type: :paragraph, children: [
        { type: :link, link_type: "id_link", id_type: "post", id: "12" },
      ] }),
      "post #12",
    )
  end

  def test_wiki_link_bakes_href_and_keeps_title
    assert_ast(
      doc({ type: :paragraph, children: [
        { type: :link, link_type: "wiki", href: "/wiki_pages/show_or_new?title=cat",
          children: [{ type: :text, content: "cat" }] },
      ] }),
      "[[cat]]",
    )
  end

  def test_bare_url_has_no_children
    assert_ast(
      doc({ type: :paragraph, children: [
        { type: :link, link_type: "url", href: "https://x.com" },
      ] }),
      "https://x.com",
    )
  end

  def test_internal_anchor
    assert_ast(
      doc({ type: :paragraph, children: [{ type: :internal_anchor, name: "foo" }] }),
      "[#foo]",
    )
  end

  def test_code_block_keeps_raw_content
    assert_ast(
      doc({ type: :code_block, content: "x < y" }),
      "[code]x < y[/code]",
    )
  end

  def test_inline_code_keeps_raw_content
    assert_ast(
      doc({ type: :paragraph, children: [{ type: :inline_code, content: "c" }] }),
      "`c`",
    )
  end

  # A deeper list item becomes a nested list sibling of the shallower item,
  # mirroring the ruby dstack's <ul><li>a</li><ul><li>b</li></ul></ul>.
  def test_nested_list_nests_a_list_beside_the_item
    assert_ast(
      doc({ type: :list, children: [
        { type: :list_item, children: [{ type: :text, content: "a" }] },
        { type: :list, children: [
          { type: :list_item, children: [{ type: :text, content: "b" }] },
        ] },
      ] }),
      "* a\n** b",
    )
  end

  def test_color_only_appears_when_allowed
    # allow_color is a parse-time argument: without it the color tags vanish and
    # the text flows bare, so no color node exists to render.
    assert_ast(
      doc({ type: :paragraph, children: [{ type: :text, content: "c" }] }),
      "[color=red]c[/color]",
      allow_color: false,
    )

    assert_ast(
      doc({ type: :paragraph, children: [
        { type: :color, color: "red", category: false,
          children: [{ type: :text, content: "c" }] },
      ] }),
      "[color=red]c[/color]",
      allow_color: true,
    )
  end

  def test_nil_input_returns_nil
    assert_nil(DText.parse_to_ast(nil))
  end
end
