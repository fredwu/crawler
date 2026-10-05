defmodule Crawler.Snapper.JavascriptReturnedClassSnapshotTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers, only: [assert_link_opens: 3, saved: 2]

  alias Crawler.Linker
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

      await_idle(opts)

      rewritten =
        Enum.reduce(targets, source, fn {name, target, _dependency}, source ->
          String.replace(source, ~s|"./#{name}.js"|, ~s|"#{Linker.offline_link(page, target)}"|)
        end)

      prefix = if type == "text/html", do: <<0xEF, 0xBB, 0xBF>>, else: ""
      assert File.read!(saved(root, page)) == prefix <> wrap(rewritten, type, goal)
      assert Store.find_processed({page, scope}).body == body

      for {_name, target, dependency} <- targets do
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
