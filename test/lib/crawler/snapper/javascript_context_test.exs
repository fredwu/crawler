defmodule Crawler.Snapper.JavascriptContextTest do
  use Crawler.OfflineLinkCase, async: true

  alias Crawler.Parser
  alias Crawler.Snapper.LinkReplacer

  @white_space [0x09, 0x0B, 0x0C, 0x20, 0xA0, 0x1680] ++
                 Enum.to_list(0x2000..0x200A) ++ [0x202F, 0x205F, 0x3000, 0xFEFF]

  test "discovers and rewrites imports after ordinary of division in modules and inline scripts" do
    for prefix <- [
          "const of=4;const n=of / 2;",
          "const n=obj?. /* café */ of / 2;",
          "for (let of=4;of / 2;of--) {}",
          "for (const value of values.map(of => of / 2)) {}"
        ] do
      source =
        prefix <>
          ~S|import("./real.js");const r=/x/;for (const value of /import(".\/hidden.js")/.exec(text)) {}|

      assert_discovered_and_rewritten(source, ["./real.js"])
    end
  end

  test "discovers and rewrites whitespace-separated modules while preserving all other bytes" do
    for char <- @white_space do
      gap = <<char::utf8>>

      source =
        "const π=1;#{gap}import#{gap}\"./side.js\";" <>
          "#{gap}import#{gap}π#{gap}from#{gap}\"./from.js\";" <>
          "#{gap}export#{gap}{π}#{gap}from#{gap}\"./named.js\";" <>
          "#{gap}export#{gap}*#{gap}from#{gap}\"./star.js\";" <>
          "#{gap}import#{gap}(#{gap}\"./dynamic.js\"#{gap});" <>
          ~s|const text="#{gap}import './hidden.js'";obj.#{gap}import("./hidden.js");|

      assert_discovered_and_rewritten(source, [
        "./side.js",
        "./from.js",
        "./named.js",
        "./star.js",
        "./dynamic.js"
      ])
    end
  end

  test "discovers and rewrites classic contextual bindings while preserving keyword regexes" do
    for {word, header} <- [{"await", "async function f()"}, {"yield", "function* f()"}] do
      source =
        "const #{word}=4;const n=#{word} / 2;" <>
          ~S|import("./real.js");const r=/x/;| <>
          "#{header} {#{word}" <> ~S| /import(".\/hidden.js")/;}|

      assert_discovered_and_rewritten(source, ["./real.js"], "")
    end

    for word <- ~w(await yield), parameters <- [word, "{name:#{word}=4}", "[#{word}=4]"] do
      source =
        "const f=(#{parameters})=>#{word} / 2;" <>
          ~S|import("./real.js");const r=/x/;|

      assert_discovered_and_rewritten(source, ["./real.js"], "")
    end
  end

  test "discovers and rewrites classic function class and catch bindings" do
    for prefix <- [
          "function await(){}const n=await / 2;",
          "function yield(){}const n=yield / 2;",
          "class await{}const n=await / 2;",
          "const f=function await(){const n=await / 2;};",
          "try{}catch({name:await=4}){const n=await / 2;}",
          "try{}catch([yield]){const n=yield / 2;}"
        ] do
      assert_discovered_and_rewritten(
        prefix <> ~S|import("./real.js");const r=/x/;|,
        ["./real.js"],
        ""
      )
    end
  end

  test "discovers and rewrites contextual identifiers supplied by another classic script" do
    for word <- ~w(await yield), header <- ["function f()", "const f=()=>"] do
      source =
        "globalThis.#{word}=4;#{header}{const n=#{word} / 2;" <>
          ~S|import("./real.js");const r=/x/;}|

      assert_discovered_and_rewritten(source, ["./real.js"], "")
    end
  end

  defp assert_discovered_and_rewritten(source, specifiers, script_type \\ "module") do
    script = if script_type == "", do: "<script>", else: ~s|<script type="#{script_type}">|

    for {body, type, tag} <- [
          {source, "application/javascript", "script"},
          {script <> source <> "</script>", "text/html", "a"}
        ] do
      opts = %{
        url: @page,
        referrer_url: @page,
        content_type: type,
        html_tag: tag,
        assets: ["js"],
        javascript_goal: if(script_type == "", do: :script, else: :module)
      }

      expected_links =
        Enum.map(specifiers, fn specifier ->
          {:ok, target} = Crawler.URL.resolve(specifier, @page)
          target
        end)

      parent = self()

      Parser.parse_links(body, opts, fn {_tag, _raw, _attribute, target}, _opts ->
        send(parent, {:link, target})
      end)

      for target <- expected_links, do: assert_receive({:link, ^target})
      refute_receive {:link, _target}, 0

      expected =
        Enum.reduce(specifiers, body, fn specifier, result ->
          {:ok, target} = Crawler.URL.resolve(specifier, @page)
          String.replace(result, ~s|"#{specifier}"|, ~s|"#{Linker.offline_link(@page, target)}"|)
        end)

      assert {:ok, rewritten} =
               LinkReplacer.replace_links(body, Map.merge(opts, %{depth: 1, max_depths: 3}))

      assert rewritten == expected

      for target <- expected_links, do: assert_points(rewritten, @page, target)
    end
  end
end
