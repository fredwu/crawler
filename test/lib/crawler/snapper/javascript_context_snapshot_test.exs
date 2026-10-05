defmodule Crawler.Snapper.JavascriptContextSnapshotTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers, only: [assert_link_opens: 3, saved: 2]

  alias Crawler.Linker
  alias Crawler.Store
  alias Crawler.URL

  @source "const of=4;const n=of / 2;import(\"./division.js\");const r=/x/;" <>
            "\uFEFFimport\uFEFF\"./side.js\";" <>
            "\uFEFFimport π from\uFEFF\"./from.js\";" <>
            "\uFEFFexport {π} from\uFEFF\"./named.js\";" <>
            "\uFEFFexport * from\uFEFF\"./star.js\";" <>
            ~S|for (const value of /import(".\/hidden.js")/.exec(text)) {}|
  @specifiers ~w(division side from named star)

  for {name, type} <- [{"app.js", "application/javascript"}, {"index.html", "text/html"}] do
    test "saves #{name} with original interior FEFF and division bytes", context do
      name = unquote(name)
      type = unquote(type)
      scope = unique_scope("javascript-context-#{name}")
      root = tmp(scope)
      page = context.url <> "/modules/" <> name
      body = wrap(@source, type)
      on_exit(fn -> File.rm_rf(root) end)

      ReqTestSite.expect_once(context.site, "GET", URI.parse(page).path, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", type)
        |> Plug.Conn.resp(200, body)
      end)

      targets =
        Enum.map(@specifiers, fn specifier ->
          {:ok, target} = URL.resolve("./#{specifier}.js", page)
          dependency = "export const π=1;"

          ReqTestSite.expect_once(context.site, "GET", URI.parse(target).path, fn conn ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/javascript")
            |> Plug.Conn.resp(200, dependency)
          end)

          {target, dependency}
        end)

      assert {:ok, opts} =
               start_crawl(page,
                 scope: scope,
                 workers: 1,
                 max_depths: 2,
                 assets: ["js"],
                 store: Store,
                 save_to: root,
                 req_options: context.req_options
               )

      await_idle(opts)

      rewritten =
        Enum.reduce(@specifiers, @source, fn specifier, source ->
          {:ok, target} = URL.resolve("./#{specifier}.js", page)

          String.replace(
            source,
            ~s|"./#{specifier}.js"|,
            ~s|"#{Linker.offline_link(page, target)}"|
          )
        end)

      prefix = if type == "text/html", do: <<0xEF, 0xBB, 0xBF>>, else: ""
      assert File.read!(saved(root, page)) == prefix <> wrap(rewritten, type)
      assert Store.find_processed({page, scope}).body == body

      for {target, dependency} <- targets do
        assert File.read!(saved(root, target)) == dependency
        assert Store.find_processed({target, scope}).body == dependency
        assert_link_opens(root, page, target)
      end
    end
  end

  @classic_source ~S|const \u0061wait=4;const n=await / 2;import("./division.js");| <>
                    ~S|const y=yield / 2;function yield(){}const r=/x/;| <>
                    ~S|const object={"f"(){const n=await / 2;import("./method.js");},| <>
                    ~S|get 12(){const n=await / 2;import("./getter.js");},| <>
                    ~S|async "a"(){await /import(".\/hidden.js")/;},| <>
                    ~S|* 0xFF(){yield /import(".\/hidden.js")/;}};|

  for {name, type} <- [{"classic.js", "application/javascript"}, {"classic.html", "text/html"}] do
    test "saves #{name} with escaped names later declarations and complete method grammar",
         context do
      name = unquote(name)
      type = unquote(type)
      scope = unique_scope("javascript-goal-#{name}")
      root = tmp(scope)
      page = context.url <> "/modules/" <> name
      body = classic_wrap(@classic_source, type)
      on_exit(fn -> File.rm_rf(root) end)

      ReqTestSite.expect_once(context.site, "GET", URI.parse(page).path, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", type)
        |> Plug.Conn.resp(200, body)
      end)

      targets =
        Enum.map(~w(division method getter), fn name ->
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
                 javascript_goal: :script,
                 store: Store,
                 save_to: root,
                 req_options: context.req_options
               )

      await_idle(opts)

      rewritten =
        Enum.reduce(targets, @classic_source, fn {name, target, _dependency}, source ->
          String.replace(source, ~s|"./#{name}.js"|, ~s|"#{Linker.offline_link(page, target)}"|)
        end)

      prefix = if type == "text/html", do: <<0xEF, 0xBB, 0xBF>>, else: ""
      assert File.read!(saved(root, page)) == prefix <> classic_wrap(rewritten, type)
      assert Store.find_processed({page, scope}).body == body

      for {_name, target, dependency} <- targets do
        assert File.read!(saved(root, target)) == dependency
        assert Store.find_processed({target, scope}).body == dependency
        assert_link_opens(root, page, target)
      end
    end
  end

  defp classic_wrap(source, "text/html"), do: "<script>#{source}</script>"
  defp classic_wrap(source, "application/javascript"), do: source

  defp wrap(source, "text/html"), do: ~s|<script type="module">#{source}</script>|
  defp wrap(source, "application/javascript"), do: source
end
