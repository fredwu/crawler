defmodule Crawler.Parser.SubresourceLoadsTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser
  alias Crawler.Parser.CssParser

  @page "http://example.com/start"
  @origin "http://example.com"

  test "an image submit button uses the images switch" do
    source = """
    <input type="image" src="/go.png" alt="Go">
    <input type="Image" src="/also.png">
    <input type="text" src="/nope.png">
    <input type="image/png" src="/typed.png">
    <input type=" image " src="/spaced.png">
    <input src="/also-nope.png">
    """

    assert refs(source, ["images"]) == [
             {"/go.png", @origin <> "/go.png", "img", nil, nil},
             {"/also.png", @origin <> "/also.png", "img", nil, nil}
           ]

    assert refs(source, []) == []
  end

  test "preload as matches the loaded resource" do
    source = """
    <link rel="preload" as="audio" href="/preload.mp3">
    <link rel="preload" as="Video" href="/preload.mp4">
    <link rel="preload" as="document" href="/next">
    <link rel="preload" as="fetch" href="/notes.html">
    <link rel="preload" as="worker" href="/w.js">
    <link rel="preload" as="serviceworker" href="/sw.js">
    <link rel="preload" as="sharedworker" href="/shared.js">
    <link rel="preload" as="paintworklet" href="/paint.js">
    <link rel="preload" as="audioworklet" href="/heard.js">
    <link rel="preload" as=" fetch " href="/spaced.json">
    """

    assert refs(source, []) == [
             {"/next", @origin <> "/next", "a", nil, nil}
           ]

    assert refs(source, ["images"]) == [
             {"/preload.mp3", @origin <> "/preload.mp3", "audio", nil, nil},
             {"/preload.mp4", @origin <> "/preload.mp4", "video", nil, nil},
             {"/next", @origin <> "/next", "a", nil, nil},
             {"/notes.html", @origin <> "/notes.html", "fetch", nil, nil}
           ]

    assert refs(source, ["js"]) == [
             {"/next", @origin <> "/next", "a", nil, nil},
             {"/notes.html", @origin <> "/notes.html", "fetch", nil, nil},
             {"/w.js", @origin <> "/w.js", "script", :script, @origin <> "/w.js"},
             {"/sw.js", @origin <> "/sw.js", "script", :script, @origin <> "/sw.js"},
             {"/shared.js", @origin <> "/shared.js", "script", :script, @origin <> "/shared.js"},
             {"/paint.js", @origin <> "/paint.js", "script", :module, @origin <> "/paint.js"},
             {"/heard.js", @origin <> "/heard.js", "script", :module, @origin <> "/heard.js"}
           ]
  end

  test "paint and audio worklet calls are modules and other addModule calls are not" do
    source = """
    <script type="importmap">{"imports":{"vue":"/vue.js"}}</script>
    <script>
    CSS.paintWorklet.addModule("./paint.js");
    audio.audioWorklet.addModule(new URL("./proc.js", import.meta.url));
    window.CSS.paintWorklet.addModule("/win.js");
    loader.addModule("./nope.js");
    fetch("./nope.png");
    import.meta.resolve("./nope.png");
    </script>
    <script type="module">
    audio.audioWorklet.addModule(new URL("./mod.js", import.meta.url));
    new URL("./pic.png", import.meta.url);
    </script>
    """

    assert refs(source, ["js"]) == [
             {"./paint.js", @origin <> "/paint.js", "script", :module, @origin <> "/paint.js"},
             {"./proc.js", @origin <> "/proc.js", "script", :module, @origin <> "/proc.js"},
             {"/win.js", @origin <> "/win.js", "script", :module, @origin <> "/win.js"},
             {"./mod.js", @origin <> "/mod.js", "script", :module, @origin <> "/mod.js"},
             {"./pic.png", @origin <> "/pic.png", "link", nil, nil}
           ]

    assert refs(source, []) == []
  end

  test "css image() records a quoted file and leaves a colour, a bare word, and a data image" do
    source = """
    div { background: image("wide.png"); }
    div { background: image(ltr "left.png", #ccc); }
    div { background: image(url("already.png")); }
    div { background: image("data:image/png,aaa"); }
    div { background: image(wide.png); }
    div { background: image-set("set.png" 1x); }
    """

    assert CssParser.parse(source) == [
             {"link", [{"href", "wide.png"}], []},
             {"link", [{"href", "left.png"}], []},
             {"link", [{"href", "already.png"}], []},
             {"link", [{"href", "set.png"}], []}
           ]
  end

  defp refs(source, assets) do
    source
    |> Parser.parse_links(
      %{url: @page, content_type: "text/html", html_tag: "a", assets: assets},
      fn
        {_, raw, _, url}, opts -> row(raw, url, opts)
        {_, url}, opts -> row(url, url, opts)
      end
    )
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp row(raw, url, opts) do
    {raw, url, opts.html_tag, opts[:javascript_goal], opts[:worker_base]}
  end
end
