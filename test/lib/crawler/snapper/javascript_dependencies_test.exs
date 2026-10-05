defmodule Crawler.Snapper.JavascriptDependenciesTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers, only: [assert_link_opens: 3, saved: 2]

  alias Crawler.Linker
  alias Crawler.Parser.JsParser
  alias Crawler.Store
  alias Crawler.URL

  @imports [
    {"import(", ~S|"./chunk.js"|, ");", "./chunk.js"},
    {"import(", ~S|"./user's.js"|, ");", "./user's.js"},
    {"import helper from ", ~S|'./say"hi.js'|, ";", ~s|./say"hi.js|},
    {"export { value as spaced } from ", ~S|"./user\u0020file.js"|, ";", "./user file.js"},
    {"import(", ~S|"./\x68ex.js"|, ");", "./hex.js"},
    {"export { value as cafe } from ", ~S|"./caf\u00e9.js"|, ";", "./café.js"},
    {~S|import { "name" as name } from |, ~S|"./quoted-import.js"|, ";", "./quoted-import.js"},
    {~S|export { name as "name" } from |, ~S|"./quoted-export.js"|, ";", "./quoted-export.js"}
  ]
  @prefix ~S|const label = "café"; const obj = {} / 2; const n = function() {} / 2; const type = class extends Factory({}) {} / 2; const arrow = () => { {} /import(".\/hidden.js")/.test(text); };
  const property = obj.return / 2; const call = obj?./* café */catch() / 2;
  $import("./fake.js"); πimport("./fake.js"); importπ("./fake.js"); a\u0061import("./fake.js");
  const asi = 1
  function afterASI() {}
  /["']/.test(label); switch (label) { case "café": async function inCase() {} /["']/.test(label); break; }
  |
  @suffix ~S|const r = /x/; const text = "import(\"./fake.js\")"; /* import("./hidden.js"); */ import("react"); import("./computed.js" + name); import(`./${name}.js`);|

  for {name, content_type} <- [{"app.js", "application/javascript"}, {"index.html", "text/html"}] do
    test "crawls and saves cooked dependencies from #{name} with paths that open", context do
      name = unquote(name)
      content_type = unquote(content_type)
      scope = unique_scope("javascript-literals-#{name}")
      root = tmp(scope)
      page = context.url <> "/modules/" <> name
      source = module_source(fn literal, _cooked -> literal end)
      body = wrap(source, content_type)
      on_exit(fn -> File.rm_rf(root) end)

      ReqTestSite.expect_once(context.site, "GET", URI.parse(page).path, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", content_type)
        |> Plug.Conn.resp(200, body)
      end)

      targets =
        Enum.map(@imports, fn {_head, _literal, _tail, cooked} ->
          assert {:ok, target} = URL.resolve(cooked, page)

          dependency =
            ~s|export default #{inspect(cooked)}; export const value = 1; export const name = 2;|

          wire_path =
            case cooked do
              "./café.js" -> "/modules/caf%c3%a9.js"
              _ -> URI.parse(target).path
            end

          ReqTestSite.expect_once(context.site, "GET", wire_path, fn conn ->
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
        module_source(fn literal, cooked ->
          {:ok, target} = URL.resolve(cooked, page)
          quote = binary_part(literal, 0, 1)
          quote <> Linker.offline_link(page, target) <> quote
        end)

      saved_body = if content_type == "text/html", do: <<0xEF, 0xBB, 0xBF>>, else: ""
      assert File.read!(saved(root, page)) == saved_body <> wrap(rewritten, content_type)
      assert length(JsParser.specs(rewritten)) == length(@imports)

      for {target, dependency} <- targets do
        assert Store.find_processed({target, scope}).body == dependency
        assert File.read!(saved(root, target)) == dependency
        assert_link_opens(root, page, target)
      end
    end
  end

  defp module_source(literal) do
    @prefix <>
      Enum.map_join(@imports, fn {head, raw, tail, cooked} ->
        head <> literal.(raw, cooked) <> tail
      end) <>
      @suffix
  end

  defp wrap(source, "text/html"), do: ~s|<script type="module">#{source}</script>|
  defp wrap(source, "application/javascript"), do: source
end
