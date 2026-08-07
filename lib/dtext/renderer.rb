# frozen_string_literal: true

class DText
  # Renders the AST from `DText.parse_to_ast`. `DText.parse` renders in C++
  # through `c_render` and does not call this class. `render` returns
  # `[html, post_ids]`.
  class Renderer
    # ext/dtext/html_sink.h lists the same values for each id link in ID_META.

    # Display name per id-link type. Ruby renders id links as "<name> #<id>"
    # regardless of the source spelling, so `Pool`/`POOL` both show `pool` and
    # `bur` shows `BUR`. A thumbnail borrows the post name.
    ID_DISPLAY = {
      "post" => "post", "thumb" => "post", "post_changes" => "post changes",
      "flag" => "flag", "note" => "note", "forum_post" => "forum",
      "topic" => "topic", "comment" => "comment", "pool" => "pool",
      "user" => "user", "artist" => "artist", "ban" => "ban", "bur" => "BUR",
      "alias" => "alias", "implication" => "implication",
      "mod_action" => "mod action", "record" => "record", "wiki" => "wiki",
      "set" => "set", "blip" => "blip", "ticket" => "ticket",
      "appeal" => "appeal", "takedown" => "takedown"
    }.freeze

    # URL path per id-link type. The id is appended directly.
    ID_ROUTE = {
      "post" => "/posts/", "thumb" => "/posts/",
      "post_changes" => "/post_versions?search[post_id]=",
      "flag" => "/post_flags/", "note" => "/notes/",
      "forum_post" => "/forum_posts/", "topic" => "/forum_topics/",
      "comment" => "/comments/", "pool" => "/pools/", "user" => "/users/",
      "artist" => "/artists/", "ban" => "/bans/",
      "bur" => "/bulk_update_requests/", "alias" => "/tag_aliases/",
      "implication" => "/tag_implications/", "mod_action" => "/mod_actions/",
      "record" => "/user_feedbacks/", "wiki" => "/wiki_pages/",
      "set" => "/post_sets/", "blip" => "/blips/", "ticket" => "/tickets/",
      "appeal" => "/appeals/", "takedown" => "/takedowns/"
    }.freeze

    # The class-name infix per id-link type. The anchor class is
    # "dtext-link dtext-id-link dtext-<infix>-id-link"; the infix diverges from
    # the type name where the route does (`bur` becomes `bulk-update-request`).
    ID_INFIX = {
      "post" => "post", "post_changes" => "post-changes-for",
      "flag" => "post-flag", "note" => "note", "forum_post" => "forum-post",
      "topic" => "forum-topic", "comment" => "comment", "pool" => "pool",
      "user" => "user", "artist" => "artist", "ban" => "ban",
      "bur" => "bulk-update-request", "alias" => "tag-alias",
      "implication" => "tag-implication", "mod_action" => "mod-action",
      "record" => "user-feedback", "wiki" => "wiki-page", "set" => "set",
      "blip" => "blip", "ticket" => "ticket", "appeal" => "appeal",
      "takedown" => "takedown"
    }.freeze

    HTML_ESCAPE = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;" }.freeze

    def self.render(ast, inline: false, max_thumbs: 25, base_url: nil)
      new(inline: inline, max_thumbs: max_thumbs, base_url: base_url).render_document(ast)
    end

    def initialize(inline:, max_thumbs:, base_url:)
      @inline = inline
      @max_thumbs = max_thumbs
      @base_url = base_url
      @thumb_count = 0
      @post_ids = []
      @out = +""
    end

    def render_document(node)
      render_all(node[:children])
      [@out, @post_ids]
    end

    private

    def render_all(nodes)
      nodes&.each { |node| render(node) }
    end

    def render(node)
      case node[:type]
      when :document then render_all(node[:children])
      when :header then wrap_block("<h#{node[:level]}>", "</h#{node[:level]}>", node)
      when :paragraph then render_paragraph(node)
      when :quote then render_quote(node)
      when :spoiler_block then wrap_block(%(<div class="spoiler">), "</div>", node)
      when :section then render_section(node)
      when :code_block then render_code_block(node)
      when :raw_block_text then @out << content(node) unless @inline
      when :table then wrap_block(%(<table class="striped">), "</table>", node)
      when :table_head then wrap_block("<thead>", "</thead>", node)
      when :table_body then wrap_block("<tbody>", "</tbody>", node)
      when :table_row then wrap_block("<tr>", "</tr>", node)
      when :table_cell then wrap_block("<#{node[:cell_type]}>", "</#{node[:cell_type]}>", node)
      when :list then wrap_block("<ul>", "</ul>", node)
      when :list_item then wrap_block("<li>", "</li>", node)
      when :text then @out << html_escape(content(node))
      when :bold then wrap_inline("<strong>", "</strong>", node)
      when :italic then wrap_inline("<em>", "</em>", node)
      when :strikeout then wrap_inline("<s>", "</s>", node)
      when :underline then wrap_inline("<u>", "</u>", node)
      when :superscript then wrap_inline("<sup>", "</sup>", node)
      when :subscript then wrap_inline("<sub>", "</sub>", node)
      when :inline_spoiler then wrap_inline(%(<span class="spoiler">), "</span>", node)
      when :inline_code then @out << %(<span class="inline-code">#{html_escape(content(node))}</span>)
      when :color then render_color(node)
      when :link then render_link(node)
      when :internal_anchor then @out << %(<a id="#{uri_escape(ascii_lower(node[:name]))}"></a>)
      when :line_break then @out << "<br>"
      else raise Error, "unknown node type: #{node[:type]}"
      end
    end

    # In inline mode the wrappers are absent and only the inline children
    # render.
    def wrap_block(open, close, node)
      @out << open unless @inline
      render_all(node[:children])
      @out << close unless @inline
    end

    def wrap_inline(open, close, node)
      @out << open
      render_all(node[:children])
      @out << close
    end

    # Drops one trailing <br>, then drops an empty <p> without a </p>, or closes
    # it. This runs on the finished string rather than the tree because an
    # inline element that renders to nothing, such as a color with allow_color
    # off, can bury the last <br>.
    def render_paragraph(node)
      @out << "<p>" unless @inline
      render_all(node[:children])

      @out.slice!(-4, 4) if @out.bytesize > 4 && @out.end_with?("<br>")
      return if @inline

      if @out.bytesize > 3 && @out.end_with?("<p>")
        @out.slice!(-3, 3)
      else
        @out << "</p>"
      end
    end

    def render_quote(node)
      color = node[:color]
      unless @inline
        if color.nil?
          @out << "<blockquote>"
        elsif node[:category]
          @out << %(<blockquote class="dtext-sidebar-colored-#{uri_escape(color)}">)
        else
          @out << %(<blockquote class="dtext-quote-color" style="border-left-color:#{color_value(color)}">)
        end
      end
      render_all(node[:children])
      @out << "</blockquote>" unless @inline
    end

    # In inline mode the summary text renders before the body, without the
    # <details>/<summary>/<div> wrappers.
    def render_section(node)
      title = node[:title]
      if @inline
        @out << html_escape(title) if title
        render_all(node[:children])
        return
      end
      @out << (node[:expanded] ? "<details open><summary>" : "<details><summary>")
      @out << html_escape(title) if title
      @out << "</summary><div>"
      render_all(node[:children])
      @out << "</div></details>"
    end

    def render_code_block(node)
      body = html_escape(content(node))
      @inline ? (@out << body) : (@out << "<pre>#{body}</pre>")
    end

    # The parser only emits a color node when color is allowed, so reaching
    # here always means a rendered span.
    def render_color(node)
      if node[:category]
        @out << %(<span class="dtext-color-#{uri_escape(node[:color])}">)
      else
        @out << %(<span class="dtext-color" style="color:#{color_value(node[:color])}">)
      end
      render_all(node[:children])
      @out << "</span>"
    end

    def render_link(node)
      return render_id_link(node) if node[:link_type] == "id_link"

      raw_href = node[:href]
      href = base_prefix(node[:link_type], raw_href) + html_escape(raw_href)
      @out << %(<a rel="nofollow" class="#{link_classes(node[:link_type], raw_href)}" href="#{href}">)
      if node[:children]
        render_all(node[:children])
      else
        @out << html_escape(raw_href)
      end
      @out << "</a>"
    end

    def render_id_link(node)
      id_type = node[:id_type]
      id = node[:id]
      if id_type == "thumb" && @thumb_count < @max_thumbs
        @thumb_count += 1
        @post_ids << id.to_i
        href = id_href("/posts/#{uri_escape(id)}")
        @out << %(<a class="dtext-link dtext-id-link dtext-post-id-link thumb-placeholder-link" data-id="#{html_escape(id)}" href="#{href}">post ##{html_escape(id)}</a>)
      else
        # A plain id link, and the path an over-budget thumbnail falls back to.
        type = id_type == "thumb" ? "post" : id_type
        href = id_href("#{ID_ROUTE[type]}#{uri_escape(id)}")
        @out << %(<a class="dtext-link dtext-id-link dtext-#{ID_INFIX[type]}-id-link" href="#{href}">#{html_escape(ID_DISPLAY[type])} ##{html_escape(id)}</a>)
      end
    end

    def link_classes(link_type, href)
      case link_type
      when "url" then "dtext-link"
      when "inline" then internal?(href) ? "dtext-link" : "dtext-link dtext-external-link"
      when "wiki" then "dtext-link dtext-wiki-link"
      when "post_search" then "dtext-link dtext-post-search-link"
      end
    end

    # Returns base_url as a bare prefix, unescaped, for the caller to join with
    # an escaped path. A named link takes it for both / and # hrefs, and a wiki
    # anchor never does.
    def base_prefix(link_type, href)
      return "" if @base_url.nil? || @base_url.empty?

      case link_type
      when "inline" then internal?(href) ? @base_url : ""
      when "wiki" then href.start_with?("/") ? @base_url : ""
      when "post_search" then @base_url
      else ""
      end
    end

    def id_href(path)
      prefix = @base_url && !@base_url.empty? && (path.start_with?("/") || path.start_with?("#")) ? @base_url : ""
      prefix + html_escape(path)
    end

    def internal?(href)
      href.start_with?("/") || href.start_with?("#")
    end

    # The `#`-prefixed hex form keeps its leading byte literal; the rest is
    # percent-escaped, matching the parser's border-left-color / color handling.
    def color_value(color)
      color.start_with?("#") ? "##{uri_escape(color[1..])}" : uri_escape(color)
    end

    def content(node)
      node[:content] || ""
    end

    # match? scans without building a new string, so text with no special byte
    # skips the gsub allocation.
    def html_escape(str)
      return str unless str.match?(/[&<>"]/)

      str.gsub(/[&<>"]/, HTML_ESCAPE)
    end

    # Escapes by byte, so a non-ASCII character becomes its UTF-8 bytes
    # (%C3%A9) and matches uri_escape in ext/dtext/dtext.cpp.rl.
    def uri_escape(str)
      return str unless str.match?(/[^a-zA-Z0-9\-_.~]/)

      str.b.gsub(/[^a-zA-Z0-9\-_.~]/) { |byte| format("%%%02X", byte.ord) }.force_encoding(Encoding::UTF_8)
    end

    def ascii_lower(str)
      return str unless str.match?(/[A-Z]/)

      str.gsub(/[A-Z]/) { |c| (c.ord + 32).chr }
    end
  end
end
