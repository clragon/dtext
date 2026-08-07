#include "dtext.h"
#include "render.h"

#include <ruby.h>
#include <ruby/encoding.h>

#include <unordered_map>
#include <variant>

static VALUE cDText = Qnil;
static VALUE cDTextError = Qnil;

// Type tags and attribute keys are stable string literals from ast.h, so the
// pointer works as a cache key and each symbol is interned once.
static VALUE sym(const char* key) {
  static std::unordered_map<const char*, VALUE> cache;
  auto found = cache.find(key);
  if (found != cache.end()) {
    return found->second;
  }
  VALUE symbol = ID2SYM(rb_intern(key));
  cache.emplace(key, symbol);
  return symbol;
}

// Turns one AST node into `{ type:, content?, children?, <attrs...> }` with
// symbol keys. `content` and `children` are absent when empty, so a missing key
// reads as "" or [].
static VALUE node_to_ruby(const ast::Node& node) {
  VALUE hash = rb_hash_new();

  rb_hash_aset(hash, sym("type"), sym(node.type));

  if (!node.content.empty()) {
    rb_hash_aset(hash, sym("content"),
                 rb_utf8_str_new(node.content.data(), node.content.size()));
  }

  for (const auto& [key, value] : node.attrs) {
    VALUE ruby_value;
    if (std::holds_alternative<std::string>(value)) {
      const auto& s = std::get<std::string>(value);
      ruby_value = rb_utf8_str_new(s.data(), s.size());
    } else if (std::holds_alternative<long>(value)) {
      ruby_value = LONG2NUM(std::get<long>(value));
    } else {
      ruby_value = std::get<bool>(value) ? Qtrue : Qfalse;
    }
    rb_hash_aset(hash, sym(key), ruby_value);
  }

  if (!node.children.empty()) {
    VALUE array = rb_ary_new_capa(node.children.size());
    for (const auto& child : node.children) {
      rb_ary_push(array, node_to_ruby(child));
    }
    rb_hash_aset(hash, sym("children"), array);
  }

  return hash;
}

// `nil` returns `nil`, and a null byte raises DText::Error.
static VALUE c_parse(VALUE self, VALUE input, VALUE allow_color) {
  if (NIL_P(input)) {
    return Qnil;
  }

  StringValue(input);

  if (memchr(RSTRING_PTR(input), 0, RSTRING_LEN(input))) {
    rb_raise(cDTextError, "invalid byte sequence in UTF-8");
  }

  try {
    std::string_view dtext(RSTRING_PTR(input), RSTRING_LEN(input));
    ast::Node document = parse_to_ast(dtext, RTEST(allow_color));
    return node_to_ruby(document);
  } catch (std::exception& e) {
    rb_raise(cDTextError, "%s", e.what());
  }
}

// Returns `[html, post_ids]`, rendered in C++ without building the Ruby AST.
static VALUE c_render(VALUE self, VALUE input, VALUE allow_color, VALUE f_inline, VALUE max_thumbs, VALUE base_url) {
  if (NIL_P(input)) {
    return Qnil;
  }

  StringValue(input);

  if (memchr(RSTRING_PTR(input), 0, RSTRING_LEN(input))) {
    rb_raise(cDTextError, "invalid byte sequence in UTF-8");
  }

  render::Options options;
  options.f_inline = RTEST(f_inline);
  options.max_thumbs = NUM2INT(max_thumbs);
  if (!NIL_P(base_url)) {
    // StringValueCStr raises ArgumentError on an embedded null.
    options.base_url = StringValueCStr(base_url);
  }

  try {
    std::string_view dtext(RSTRING_PTR(input), RSTRING_LEN(input));
    render::Result result = render::to_html(dtext, RTEST(allow_color), options);

    VALUE html = rb_utf8_str_new(result.html.data(), result.html.size());
    VALUE post_ids = rb_ary_new_capa(result.post_ids.size());
    for (long id : result.post_ids) {
      rb_ary_push(post_ids, LONG2FIX(id));
    }

    VALUE pair = rb_ary_new_capa(2);
    rb_ary_push(pair, html);
    rb_ary_push(pair, post_ids);
    return pair;
  } catch (std::exception& e) {
    rb_raise(cDTextError, "%s", e.what());
  }
}

extern "C" void Init_dtext() {
  cDText = rb_define_class("DText", rb_cObject);
  cDTextError = rb_define_class_under(cDText, "Error", rb_eStandardError);
  rb_define_singleton_method(cDText, "c_parse", c_parse, 2);
  rb_define_singleton_method(cDText, "c_render", c_render, 5);
}
