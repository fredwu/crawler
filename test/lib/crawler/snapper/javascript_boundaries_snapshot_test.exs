defmodule Crawler.Snapper.JavascriptBoundariesSnapshotTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers,
    only: [
      assert_opens: 4,
      read_resource: 2,
      ready_export: 1,
      reference_target: 3,
      relative_reference: 2,
      resource_for_url: 2
    ]

  alias Crawler.Parser.JsParser
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
      root = Path.join(tmp(scope), "archive")
      page = context.url <> "/modules/" <> name
      body = wrap(source, type, goal)
      on_exit(fn -> File.rm_rf(Path.dirname(root)) end)

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

      export = ready_export(opts)
      resource = resource_for_url(export, page)

      rewritten =
        Enum.reduce(targets, source, fn {raw, target, _dependency}, source ->
          String.replace(
            source,
            ~s|"#{raw}"|,
            ~s|"#{relative_reference(resource, reference_target(export, resource, target))}"|
          )
        end)

      prefix = if type == "text/html", do: <<0xEF, 0xBB, 0xBF>>, else: ""
      actual = read_resource(export, resource)
      assert actual == prefix <> wrap(rewritten, type, goal)
      emitted = JsParser.specs(script_source(actual, type), goal)
      assert length(emitted) == length(targets)
      assert Store.find_processed({page, scope}).body == body

      for {_raw, target, dependency} <- targets do
        target_resource = reference_target(export, resource, target)
        assert read_resource(export, target_resource) == dependency
        assert Store.find_processed({target, scope}).body == dependency

        assert [href] =
                 Enum.filter(emitted, &(&1 == relative_reference(resource, target_resource)))

        assert_opens(export, resource, target_resource, href)
      end
    end
  end

  defp script_source(body, "text/html") do
    body
    |> String.split(">", parts: 2)
    |> List.last()
    |> String.replace_suffix("</script>", "")
  end

  defp script_source(body, "application/javascript"), do: body

  defp wrap(source, "text/html", :script), do: "<script>#{source}</script>"
  defp wrap(source, "text/html", :module), do: ~s|<script type="module">#{source}</script>|
  defp wrap(source, "application/javascript", _goal), do: source
end
