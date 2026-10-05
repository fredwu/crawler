defmodule Crawler.CrawlJavascriptSourceGoalTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers

  alias Crawler.Linker
  alias Crawler.Store
  alias Crawler.URL

  @source ~S|const n=await /g;var await=4;import(".\/hidden.js");const m=g/g;import("./real.js");|
  @child_source ~S|const n=await /g;var await=4;import(".\/child-hidden.js");const m=g/g;import("./leaf.js");|
  @apps [
    {"classic", :script},
    {"module", :module},
    {"preload", :script},
    {"modulepreload", :module}
  ]
  @directories ["", "/classic", "/module", "/preload", "/modulepreload"]

  test "HTML source goals and classic import children remain exact through crawl and snapshot", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("javascript-source-goals")
    root = tmp(scope)
    page = url <> "/index.html"

    external =
      ~s|<script src="/classic/app.js"></script>| <>
        ~s|<script type="module" src="/module/app.js"></script>| <>
        ~s|<link rel="preload" as="script" href="/preload/app.js">| <>
        ~s|<link rel="modulepreload" href="/modulepreload/app.js">|

    source = ~s|<script>#{@source}</script><script type="module">#{@source}</script>| <> external
    on_exit(fn -> File.rm_rf(root) end)

    ReqTestSite.expect_once(site, "GET", "/index.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, source)
    end)

    for {directory, _goal} <- @apps do
      javascript(site, "/#{directory}/app.js", @source)
    end

    for directory <- @directories do
      javascript(site, directory <> "/real.js", @child_source)
      javascript(site, directory <> "/leaf.js", "export {};")
    end

    for directory <- ["", "/classic", "/preload"] do
      javascript(site, directory <> "/hidden.js", "export {};")
    end

    {:ok, opts} =
      start_crawl(page,
        scope: scope,
        workers: 2,
        max_depths: 4,
        retries: 0,
        assets: ["js"],
        javascript_goal: :script,
        store: Store,
        save_to: root,
        req_options: req_options
      )

    wait(2_000, fn -> refute Crawler.running?(opts) end)

    inline =
      ~s|<script>#{rewritten(@source, page, :script)}</script>| <>
        ~s|<script type="module">#{rewritten(@source, page, :module)}</script>|

    expected_page =
      Enum.reduce(@apps, inline <> external, fn {directory, _goal}, body ->
        String.replace(
          body,
          ~s|"/#{directory}/app.js"|,
          ~s|"#{Linker.offline_link(page, url <> "/#{directory}/app.js")}"|
        )
      end)

    assert File.read!(saved(root, page)) == <<0xEF, 0xBB, 0xBF>> <> expected_page
    assert Store.find_processed({page, scope}).body == source

    for {directory, goal} <- @apps do
      app = url <> "/#{directory}/app.js"
      assert Store.find_processed({app, scope}).opts.javascript_goal == goal
      assert File.read!(saved(root, app)) == rewritten(@source, app, goal)
      assert_link_opens(root, page, app)
      assert_link_opens(root, app, url <> "/#{directory}/real.js")
    end

    for directory <- @directories do
      child = url <> directory <> "/real.js"
      leaf = url <> directory <> "/leaf.js"
      assert Store.find_processed({child, scope}).opts.javascript_goal == :module
      assert File.read!(saved(root, child)) == rewritten(@child_source, child, :module, "leaf")
      assert File.read!(saved(root, leaf)) == "export {};"
      assert_link_opens(root, child, leaf)
      refute Store.find({url <> directory <> "/child-hidden.js", scope})
    end

    for directory <- ["/module", "/modulepreload"] do
      refute Store.find({url <> directory <> "/hidden.js", scope})
    end

    for directory <- ["", "/classic", "/preload"] do
      assert Store.find_processed({url <> directory <> "/hidden.js", scope}).opts.javascript_goal ==
               :module
    end
  end

  defp javascript(site, path, source) do
    ReqTestSite.expect_once(site, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/javascript")
      |> Plug.Conn.resp(200, source)
    end)
  end

  defp rewritten(source, page, goal, child \\ "real") do
    {:ok, target} = URL.resolve("./#{child}.js", page)

    source =
      String.replace(source, ~s|"./#{child}.js"|, ~s|"#{Linker.offline_link(page, target)}"|)

    if goal == :script do
      {:ok, hidden} = URL.resolve("./hidden.js", page)
      String.replace(source, ~S|".\/hidden.js"|, ~s|"#{Linker.offline_link(page, hidden)}"|)
    else
      source
    end
  end
end
