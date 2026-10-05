defmodule Crawler.Parser.SVGHrefSelectionTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser

  @opts %{
    url: "http://example.com/index.html",
    content_type: "text/html",
    html_tag: "a",
    assets: ["images", "css"]
  }

  for {tag, role} <- [{"a", "a"}, {"image", "img"}, {"use", "img"}] do
    test "SVG #{tag} selects href by presence and keeps style independent" do
      tag = unquote(tag)
      role = unquote(role)

      source =
        "<svg>" <>
          ~s|<#{tag} xlink:href="ignored.svg" href="active.svg"/>| <>
          ~s|<#{tag} xlink:href="fallback.svg" xlink:href="ignored.svg"/>| <>
          ~s|<#{tag} href="" xlink:href="ignored.svg"/>| <>
          ~s|<#{tag} href="" href="ignored.svg" xlink:href="ignored.svg" style="background:url(style.png)"/>| <>
          "</svg>"

      expected = [{"active.svg", role}, {"fallback.svg", role}, {"style.png", "link"}]
      assert references(source, @opts) == expected

      css_only = %{@opts | assets: ["css"]}
      expected = if tag == "a", do: expected, else: [{"style.png", "link"}]
      assert references(source, css_only) == expected
    end
  end

  defp references(source, opts) do
    source
    |> Parser.parse_links(opts, fn
      {_, raw, _, _url}, child -> {raw, child.html_tag}
      {_, url}, child -> {url, child.html_tag}
    end)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end
end
