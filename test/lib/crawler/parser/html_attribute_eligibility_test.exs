defmodule Crawler.Parser.HTMLAttributeEligibilityTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser

  @opts %{
    url: "http://example.com/index.html",
    content_type: "text/html",
    html_tag: "a",
    assets: ["images", "css", "js"]
  }

  test "img and source use src and srcset while ignoring imagesrcset" do
    source =
      ~s|<img src="image.png" srcset="image-set.png 1x" imagesrcset="ignored.png 1x">| <>
        ~s|<source src="source.png" srcset="source-set.png 1x" imagesrcset="ignored.png 1x">|

    assert references(source) == [
             {"image.png", "img"},
             {"image-set.png", "img"},
             {"source.png", "source"},
             {"source-set.png", "source"}
           ]
  end

  test "link imagesrcset requires the preload token and exact image state" do
    invalid = [
      "",
      ~s|rel="preload"|,
      ~s|as="image"|,
      ~s|rel="icon" as="image"|,
      ~s|rel="preload" as="script"|,
      ~s|rel="preload" as=" image "|,
      ~s|rel="preload" as="&#160;image&#160;"|,
      ~s|rel="&#160;preload&#160;" as="image"|
    ]

    for attrs <- invalid do
      assert references(~s|<link #{attrs} imagesrcset="ignored.png 1x">|) == []
    end

    source =
      ~s|<link rel=" alternate&#9;PRELOAD&#10;&#12;&#13; " as="IM&#65;GE" imagesrcset="image.png 1x">|

    assert references(source) == [{"image.png", "img"}]
    assert references(source, %{@opts | assets: []}) == []
  end

  test "rel splits ASCII whitespace while enumerated attributes do not trim" do
    source =
      ~s|<link rel="&#9;STYLESHEET&#10;" href="style.css">| <>
        ~s|<link rel="preload" as="SCRIPT" href="app.js">| <>
        ~s|<meta http-equiv="ReFrEsH" content="0; next.html">| <>
        ~s|<link rel="&#160;stylesheet&#160;" href="ignored.css">| <>
        ~s|<link rel="preload" as=" script " href="ignored.js">| <>
        ~s|<link rel="preload" as="&#160;style&#160;" href="ignored.css">| <>
        ~s|<meta http-equiv=" refresh " content="0; ignored.html">| <>
        ~s|<meta http-equiv="&#160;refresh&#160;" content="0; ignored.html">|

    assert references(source) == [
             {"style.css", "link"},
             {"app.js", "script"},
             {"next.html", "a"}
           ]
  end

  defp references(source, opts \\ @opts) do
    source
    |> Parser.parse_links(opts, fn
      {_, raw, _, _url}, child -> {raw, child.html_tag}
      {_, url}, child -> {url, child.html_tag}
    end)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end
end
