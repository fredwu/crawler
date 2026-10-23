defmodule Crawler.Snapper.JavascriptAsiSnapshotTest do
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

  @script_source "var await=4;const f=async()=>1/*\n*/const n=await / 2;" <>
                   "const increment=async()=>value\n++await / 2;" <>
                   "const decrement=async()=>value/*\n*/--await / 2;" <>
                   ~S|import("./arrow.js");const r=/x/;|
  @module_source "const f=()=>1\n" <>
                   ~S|await /import(".\/hidden.js")/;import("./arrow.js");|
  @shared_source "class C{x=1/*\n*/" <>
                   ~S|async f(){await /import(".\/hidden.js")/;}| <>
                   "y=async()=>1\n" <>
                   ~S|async g(){await /import(".\/hidden.js")/;}}import("./field.js");| <>
                   "const continued=async()=>value\n" <>
                   ~S|[await /import(".\/hidden.js")/];import("./continued.js");| <>
                   "async function run(){const inner=()=>1\n" <>
                   ~S|await /import(".\/hidden.js")/;import("./restored.js");}|
  @names ~w(arrow field continued restored)

  for {name, type, goal} <- [
        {"asi.js", "application/javascript", :script},
        {"asi.html", "text/html", :script},
        {"module-asi.js", "application/javascript", :module},
        {"module-asi.html", "text/html", :module}
      ] do
    test "saves #{name} with exact ASI and continuation bytes", context do
      name = unquote(name)
      type = unquote(type)
      goal = unquote(goal)
      source = if goal == :script, do: @script_source, else: @module_source
      source = source <> @shared_source
      scope = unique_scope("javascript-asi-#{name}")
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
        Enum.map(@names, fn name ->
          {:ok, target} = URL.resolve("./#{name}.js", page)
          dependency = "export const π=1;"

          ReqTestSite.expect_once(context.site, "GET", URI.parse(target).path, fn conn ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/javascript")
            |> Plug.Conn.resp(200, dependency)
          end)

          {name, target, dependency}
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
        Enum.reduce(targets, source, fn {name, target, _dependency}, source ->
          String.replace(
            source,
            ~s|"./#{name}.js"|,
            ~s|"#{relative_reference(resource, reference_target(export, resource, target))}"|
          )
        end)

      prefix = if type == "text/html", do: <<0xEF, 0xBB, 0xBF>>, else: ""
      actual = read_resource(export, resource)
      assert actual == prefix <> wrap(rewritten, type, goal)
      emitted = JsParser.specs(script_source(actual, type), goal)
      assert length(emitted) == length(targets)
      assert Store.find_processed({page, scope}).body == body

      for {_name, target, dependency} <- targets do
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
