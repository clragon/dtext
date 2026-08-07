require 'minitest/autorun'
require 'dtext'
require_relative 'test_helper'

# Tests for legacy tables, like [ltable]text | text[/ltable]
class DTextLegacyTableTest < Minitest::Test
  include DTextTestHelper
  LSTART = "[ltable]"
  LEND   = "[/ltable]"

  def test_table_legacy
    assert_parse("<table class=\"striped\"><thead><tr><th>test1 \\\| test2 </th><th> test2</th></tr></thead><tbody><tr><td>abc </td><td> 123</td></tr></tbody></table>", <<~END)
    #{LSTART}
    test1 \\\| test2 | test2
    abc | 123
    #{LEND}
    END

  assert_parse("<table class=\"striped\"><thead><tr><th>test1 </th><th> test2</th></tr></thead><tbody><tr><td>abc </td><td> 123</td></tr></tbody></table><table class=\"striped\"><thead><tr><th>test1 </th><th> test2</th></tr></thead><tbody><tr><td>abc </td><td> 123</td></tr></tbody></table>", <<~END)
    #{LSTART}
    test1 | test2
    abc | 123
    #{LEND}
    #{LSTART}
    test1 | test2
    abc | 123
    #{LEND}
    END

  assert_parse("<table class=\"striped\"><thead><tr><th>test1</th></tr></thead><tbody></tbody></table>", <<~END)
    #{LSTART}
    test1
    #{LEND}
    END

  assert_parse("<table class=\"striped\"><thead><tr><th>test1</th></tr></thead><tbody><tr><td>test2</td></tr></tbody></table>", <<~END)
    #{LSTART}test1
    test2#{LEND}
    END
  end

  # Edges of the [ltable] grammar, where the body ends at EOF, holds nothing,
  # breaks off mid-tag, or sits inside [code].
  def test_legacy_table_grammar_edges
    # An unterminated [ltable] closes at EOF.
    assert_parse("<table class=\"striped\"><thead><tr><th>a </th><th> b</th></tr></thead><tbody><tr><td>c </td><td> d</td></tr></tbody></table>", "[ltable]\na | b\nc | d")

    # Empty body: the stray [/tbody] reaches output as literal text.
    assert_parse("<table class=\"striped\">[/tbody]</table>", "[ltable]\n[/ltable]")

    # A partial closing tag stays part of the captured body.
    assert_parse("<table class=\"striped\"><thead><tr><th>abc[/ltab</th></tr></thead><tbody></tbody></table>", "[ltable]abc[/ltab")

    # Inside [code] an [ltable] stays literal.
    assert_parse("<pre>[ltable]a|b[/ltable]</pre>", "[code][ltable]a|b[/ltable][/code]")
  end

  def assert_legacy_table_parse(html, table)
    assert_parse(html, <<~'LEND')
    #{LSTART}
    #{table}
    #{LEND}
    LEND
  end

  # An [ltable] inside a [table] expands beside it rather than within a cell,
  # because the expansion closes the leaf blocks first.
  def test_legacy_table_inside_table
    assert_parse("<table class=\"striped\"><td>a</td></table><table class=\"striped\"><thead><tr><th>x</th><th>y</th></tr></thead><tbody></tbody></table>[/table]",
                 "[table][td]a[ltable]x|y[/ltable]b[/td][/table]")

    assert_parse("<table class=\"striped\"></table><table class=\"striped\"><thead><tr><th>a</th><th>b</th></tr></thead><tbody></tbody></table>[/table]",
                 "[table][ltable]a|b[/ltable][/table]")
  end

end
