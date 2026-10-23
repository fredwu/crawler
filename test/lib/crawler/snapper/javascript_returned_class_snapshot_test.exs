defmodule Crawler.Snapper.JavascriptReturnedClassSnapshotTest do
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

  @shared ~S|const f=()=>class{async m(){await /import(".\/hidden.js")/;}};import("./ordinary.js");| <>
            ~S|const g=async()=>class{*m(){yield /import(".\/hidden.js")/;}async *g(){await /import(".\/hidden.js")/;yield /import(".\/hidden.js")/;}};import("./async.js");| <>
            ~S|const nested=()=>function returned(cb=()=>1){return class Named extends (class{async inherited(){await /import(".\/hidden.js")/;}}){async m(){await /import(".\/hidden.js")/;import("./nested.js");}}};| <>
            ~S|const block=async()=>{await /import(".\/hidden.js")/;import("./block.js");};|
  @script_tail ~S|var await=4;const normal=async()=>class{m(){const n=await / 2;import("./normal.js");const r=/x/;}};|
  @module_tail ~S|const normal=async()=>class{m(){return import("./normal.js");}};|
  @names ~w(ordinary async nested block normal)

  for {name, type, goal} <- [
        {"returned.js", "application/javascript", :script},
        {"returned.html", "text/html", :script},
        {"module-returned.js", "application/javascript", :module},
        {"module-returned.html", "text/html", :module}
      ] do
    test "saves #{name} with exact returned class and regex bytes", context do
      name = unquote(name)
      type = unquote(type)
      goal = unquote(goal)
      tail = if goal == :script, do: @script_tail, else: @module_tail
      source = @shared <> tail
      scope = unique_scope("javascript-returned-#{name}")
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
