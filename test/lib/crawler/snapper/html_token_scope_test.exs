defmodule Crawler.Snapper.HTMLTokenScopeTest do
  use Crawler.OfflineLinkCase, async: true

  alias Crawler.HTMLSpans
  alias Crawler.Parser
  alias Crawler.Parser.HtmlParser

  for incomplete <- [
        "<a href=next",
        ~s|<a href="next"|,
        ~s|<a href="next|,
        "<img src=next.png",
        ~s|<img src='next.png|,
        "<base href=/wrong/",
        ~s|<script src="app.js"|
      ] do
    test "#{incomplete} is neither discovered nor rewritten at EOF" do
      source = unquote(incomplete)
      assert discovered(source) == []
      assert HtmlParser.parse(source, %{assets: ["images", "js"]}) == []
      assert rewrite(source, @page) == source

      prefix = ~s|<a href="real">Real</a>|
      target = "http://example.com/blog/real"
      href = Linker.offline_link(@page, target)
      assert discovered(prefix <> source) == [target]
      assert rewrite(prefix <> source, @page) == ~s|<a href="#{href}">Real</a>| <> source
    end
  end

  test "an unfinished base cannot change the preceding real anchor destination" do
    source = ~s|<a href="next">Real</a><base href="/wrong/"|
    target = "http://example.com/blog/next"
    href = Linker.offline_link(@page, target)
    assert discovered(source) == [target]
    assert HTMLSpans.base_tags(source) == []
    assert rewrite(source, @page) == ~s|<a href="#{href}">Real</a><base href="/wrong/"|
  end

  for prefix <- [
        "<div><template></div>",
        "<section><template></section>",
        "<html><body><template></body></html>",
        "<svg><foreignObject><template></foreignObject></svg>",
        ~s|<math><annotation-xml encoding="text/html"><template></annotation-xml></math>|
      ] do
    test "#{prefix} keeps its following links and base inert until the template closes" do
      prefix = unquote(prefix)

      inert =
        prefix <> ~s|<base href="/wrong/"><a href="next">In</a><img src="wrong.png">|

      source = inert <> ~s|</template><a href="next">Out</a>|
      target = "http://example.com/blog/next"
      href = Linker.offline_link(@page, target)

      assert discovered(source) == [target]
      assert HTMLSpans.base_tags(source) == []
      assert rewrite(source, @page) == inert <> ~s|</template><a href="#{href}">Out</a>|
    end
  end

  test "malformed ancestor closes cannot expose either nested template's references" do
    inert =
      ~s|<div><template><section><template></div></section><a href="next">Inner</a>| <>
        ~s|</template><base href="/wrong/"><a href="next">Outer</a>|

    source = inert <> ~s|</template><a href="next">Out</a>|
    target = "http://example.com/blog/next"
    href = Linker.offline_link(@page, target)

    assert discovered(source) == [target]
    assert rewrite(source, @page) == inert <> ~s|</template><a href="#{href}">Out</a>|
  end

  test "a real matching foreign close after a template restores subsequent HTML references" do
    inert =
      ~s|<svg><foreignObject><template></svg><a href="next">In</a></template></foreignObject></svg>|

    source = inert <> ~s|<a href="next">Out</a>|
    target = "http://example.com/blog/next"
    href = Linker.offline_link(@page, target)

    assert discovered(source) == [target]
    assert rewrite(source, @page) == inert <> ~s|<a href="#{href}">Out</a>|
  end

  defp discovered(source) do
    source
    |> Parser.parse_links(
      %{
        url: @page,
        referrer_url: @page,
        content_type: "text/html",
        html_tag: "a",
        assets: ["images", "js", "css"],
        depth: 1,
        max_depths: 3
      },
      fn
        {_attribute, url}, _opts -> url
        {"link", _raw, _attribute, url}, _opts -> url
      end
    )
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end
end
