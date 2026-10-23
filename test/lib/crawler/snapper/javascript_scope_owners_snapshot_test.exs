defmodule Crawler.Snapper.JavascriptScopeOwnersSnapshotTest do
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

  @prefix "#! import(\"./phantom.js\") '\"\r\n"
  @shared ~S|async function f(cb=()=>1){await /import(".\/hidden.js")/;import("./parameters.js");}| <>
            ~S|function* g(cb=async()=>()=>1){yield /import(".\/hidden.js")/;}| <>
            "class C{x\n" <>
            ~S|*f(cb=()=>1){yield /import(".\/hidden.js")/;}| <>
            "y/*\n*/" <>
            ~S|async *g(cb=async()=>1){await /import(".\/hidden.js")/;yield /import(".\/hidden.js")/;}}import("./fields.js");| <>
            ~S|const object={async f(cb=()=>1){await /import(".\/hidden.js")/;}};import("./methods.js");|
  @script_tail ~S|var await=4;function normal(cb=async()=>()=>1){const n=await / 2;import("./normal.js");const r=/x/;}|
  @module_tail ~S|function normal(cb=async()=>()=>1){import("./normal.js");}|
  @names ~w(parameters fields methods normal)

  for {name, type, goal} <- [
        {"owners.js", "application/javascript", :script},
        {"owners.html", "text/html", :script},
        {"module-owners.js", "application/javascript", :module},
        {"module-owners.html", "text/html", :module}
      ] do
    test "saves #{name} with exact parameter field and hashbang bytes", context do
      name = unquote(name)
      type = unquote(type)
      goal = unquote(goal)
      tail = if goal == :script, do: @script_tail, else: @module_tail
      source = @prefix <> @shared <> tail
      scope = unique_scope("javascript-owners-#{name}")
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
