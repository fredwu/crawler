defmodule Crawler.Parser.JavascriptSourceGoalTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser

  @page "http://example.com/dir/page"
  @source ~S|const n=await /g;var await=4;import(".\/hidden.js");const m=g/g;import("./real.js");|

  test "identical inline bytes use the classic or module source goal" do
    for {attrs, targets} <- [
          {"", ["./hidden.js", "./real.js"]},
          {~s|type="module"|, ["./real.js"]}
        ] do
      source = ~s|<script #{attrs}>#{@source}</script>|

      assert references(source, %{assets: ["js"]}) ==
               Enum.map(targets, &{&1, "script", :module})
    end
  end

  test "external script and preload goals stay separate from crawl policy roles" do
    source =
      ~s|<script src="classic.js"></script><script type="module" src="module.js"></script>| <>
        ~s|<link rel="preload" as="script" href="preload.js">| <>
        ~s|<link rel="modulepreload" href="modulepreload.js">|

    assert references(source, %{assets: ["js"], javascript_goal: :module}) == [
             {"classic.js", "script", :script},
             {"module.js", "script", :module},
             {"preload.js", "script", :script},
             {"modulepreload.js", "script", :module}
           ]
  end

  test "direct classic JavaScript imports always request module dependencies" do
    opts = %{content_type: "application/javascript", html_tag: "script", javascript_goal: :script}

    assert references(@source, opts) == [
             {"./hidden.js", "link", :module},
             {"./real.js", "link", :module}
           ]

    assert references(@source, Map.delete(opts, :javascript_goal)) == [
             {"./real.js", "link", :module}
           ]
  end

  test "parent JavaScript goals do not leak into navigation, CSS or image requests" do
    source =
      ~s|<a href="next" style="background:url(bg.png)">A</a>| <>
        ~s|<img src="image.png"><link rel="stylesheet" href="app.css">|

    assert references(source, %{assets: ["css", "images"], javascript_goal: :script}) == [
             {"next", "a", nil},
             {"bg.png", "link", nil},
             {"image.png", "img", nil},
             {"app.css", "link", nil}
           ]
  end

  defp references(source, options) do
    opts = Map.merge(%{url: @page, content_type: "text/html", html_tag: "a"}, options)

    source
    |> Parser.parse_links(opts, fn
      {_, raw, _, _url}, opts -> {raw, opts.html_tag, opts[:javascript_goal]}
      {_, url}, opts -> {url, opts.html_tag, opts[:javascript_goal]}
    end)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end
end
