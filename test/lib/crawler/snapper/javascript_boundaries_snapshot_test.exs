defmodule Crawler.Snapper.JavascriptBoundariesSnapshotTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers, only: [assert_link_opens: 3, saved: 2]

  alias Crawler.Linker
  alias Crawler.Store
  alias Crawler.URL

  @script_source ~S|class C{f(){}async g(){await /import(".\/hidden.js")/;}static{}*h(){yield /import(".\/hidden.js")/;}}| <>
                   ~S|const \u{0000000000000000000061}wait=4;const f=ready?async()=>await /x/:await / 2;import("./conditional.js");const r=/x/;| <>
                   ~S|async function run(){const text=`${()=>import("./inside.js")}`;await /import(".\/hidden.js")/;}| <>
                   ~S|const text=`${async()=>await /x/}`;const n=await / 2;import("./template.js");const s=/x/;| <>
                   ~S|const object={async [key({a:1})](){await /import(".\/hidden.js")/;},*[key([{},{}])](){yield /import(".\/hidden.js")/;}};| <>
                   ~S|import(".\u{000000000000000000002f}computed.js");| <>
                   ~S|const \u{0000000000000000000079}ield=4;const m=yield / 2;import("./identifier.js");const t=/x/;|
  @module_source ~S|class C{f(){}async g(){await /import(".\/hidden.js")/;}static{}*h(){yield /import(".\/hidden.js")/;}}| <>
                   ~S|const f=async()=>ready?await /import(".\/hidden.js")/:await /import(".\/hidden.js")/;import("./conditional.js");| <>
                   ~S|async function run(){const text=`${()=>import("./inside.js")}`;await /import(".\/hidden.js")/;}| <>
                   ~S|const text=`${()=>1}`;await /import(".\/hidden.js")/;import("./template.js");| <>
                   ~S|const object={async [key({a:1})](){await /import(".\/hidden.js")/;},*[key([{},{}])](){yield /import(".\/hidden.js")/;}};| <>
                   ~S|import(".\u{000000000000000000002f}computed.js");| <>
                   ~S|const \u{00000000000000000003c0}=4;import("./identifier.js");|
  @specifiers [
    {"./conditional.js", "./conditional.js"},
    {"./inside.js", "./inside.js"},
    {"./template.js", "./template.js"},
    {~S|.\u{000000000000000000002f}computed.js|, "./computed.js"},
    {"./identifier.js", "./identifier.js"}
  ]

  for {name, type, goal} <- [
        {"boundaries.js", "application/javascript", :script},
        {"boundaries.html", "text/html", :script},
        {"module.js", "application/javascript", :module},
        {"module.html", "text/html", :module}
      ] do
    test "saves #{name} with exact boundary and escape bytes", context do
      name = unquote(name)
      type = unquote(type)
      goal = unquote(goal)
      source = if goal == :script, do: @script_source, else: @module_source
      scope = unique_scope("javascript-boundaries-#{name}")
      root = tmp(scope)
      page = context.url <> "/modules/" <> name
      body = wrap(source, type, goal)
      on_exit(fn -> File.rm_rf(root) end)

      ReqTestSite.expect_once(context.site, "GET", URI.parse(page).path, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", type)
        |> Plug.Conn.resp(200, body)
      end)

      targets =
        Enum.map(@specifiers, fn {raw, specifier} ->
          {:ok, target} = URL.resolve(specifier, page)
          dependency = "export const π=1;"

          ReqTestSite.expect_once(context.site, "GET", URI.parse(target).path, fn conn ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/javascript")
            |> Plug.Conn.resp(200, dependency)
          end)

          {raw, target, dependency}
        end)

      assert {:ok, opts} =
               start_crawl(page,
                 scope: scope,
                 workers: 1,
                 max_depths: 2,
                 assets: ["js"],
                 javascript_goal: goal,
                 store: Store,
                 save_to: root,
                 req_options: context.req_options
               )

      await_idle(opts)

      rewritten =
        Enum.reduce(targets, source, fn {raw, target, _dependency}, source ->
          String.replace(source, ~s|"#{raw}"|, ~s|"#{Linker.offline_link(page, target)}"|)
        end)

      prefix = if type == "text/html", do: <<0xEF, 0xBB, 0xBF>>, else: ""
      assert File.read!(saved(root, page)) == prefix <> wrap(rewritten, type, goal)
      assert Store.find_processed({page, scope}).body == body

      for {_raw, target, dependency} <- targets do
        assert File.read!(saved(root, target)) == dependency
        assert Store.find_processed({target, scope}).body == dependency
        assert_link_opens(root, page, target)
      end
    end
  end

  defp wrap(source, "text/html", :script), do: "<script>#{source}</script>"
  defp wrap(source, "text/html", :module), do: ~s|<script type="module">#{source}</script>|
  defp wrap(source, "application/javascript", _goal), do: source
end
