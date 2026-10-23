defmodule Crawler.CrawlJavascriptSourceGoalTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

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
    root = tmp(scope, "archive")
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
        workers: 1,
        max_body: 1_048_576,
        max_analysis_bytes: 16 * 1024 * 1024,
        max_manifest_bytes: 16 * 1024 * 1024,
        max_depths: 4,
        retries: 0,
        assets: ["js"],
        javascript_goal: :script,
        store: Store,
        save_to: root,
        req_options: req_options
      )

    export = ready_export(opts)
    page_resource = resource_for_url(export, page)

    saved_page = read_resource(export, page_resource)

    [classic_source, module_source] =
      List.flatten(
        Regex.scan(~r/<script(?: type="module")?>(.*?)<\/script>/s, saved_page,
          capture: :all_but_first
        )
      )

    assert [classic_reference] =
             Regex.run(~r/import\("([^"]+)"\);$/, classic_source, capture: :all_but_first)

    assert [module_reference] =
             Regex.run(~r/import\("([^"]+)"\);$/, module_source, capture: :all_but_first)

    inline =
      ~s|<script>#{rewritten(@source, export, page_resource, :script, "real", classic_reference)}</script>| <>
        ~s|<script type="module">#{rewritten(@source, export, page_resource, :module, "real", module_reference)}</script>|

    expected_page =
      Enum.reduce(@apps, inline <> external, fn {directory, _goal}, body ->
        String.replace(
          body,
          ~s|"/#{directory}/app.js"|,
          ~s|"#{relative_reference(page_resource, reference_target(export, page_resource, url <> "/#{directory}/app.js"))}"|
        )
      end)

    assert read_resource(export, page_resource) == <<0xEF, 0xBB, 0xBF>> <> expected_page
    assert Store.find_processed({page, scope}).body == source

    for {directory, goal} <- @apps do
      app = url <> "/#{directory}/app.js"
      assert Store.find_processed({app, scope}).opts.javascript_goal == goal
      app_resource = reference_target(export, page_resource, app)
      assert read_resource(export, app_resource) == rewritten(@source, export, app_resource, goal)
      assert_link_opens(export, page_resource, app_resource)

      assert_link_opens(
        export,
        app_resource,
        reference_target(export, app_resource, url <> "/#{directory}/real.js")
      )
    end

    for directory <- @directories do
      child = url <> directory <> "/real.js"
      leaf = url <> directory <> "/leaf.js"
      assert Store.find_processed({child, scope}).opts.javascript_goal == :module

      child_edges = Enum.filter(export.manifest["references"], &(&1["url"] == child))
      assert child_edges != []

      child_resources =
        child_edges
        |> Enum.map(&edge_target(export, resource_by_id(export, &1["from"]), &1["edge"]))
        |> Enum.uniq_by(& &1["id"])

      for child_resource <- child_resources do
        leaf_resource = reference_target(export, child_resource, leaf)

        assert read_resource(export, child_resource) ==
                 rewritten(@child_source, export, child_resource, :module, "leaf")

        assert read_resource(export, leaf_resource) == "export {};"
        assert_link_opens(export, child_resource, leaf_resource)
      end

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

  defp rewritten(source, export, resource, goal, child \\ "real", actual_reference \\ nil) do
    {:ok, target_url} = URL.resolve("./#{child}.js", resource["url"])

    targets =
      export.manifest["references"]
      |> Enum.filter(&(&1["from"] == resource["id"] and &1["url"] == target_url))
      |> Enum.map(&edge_target(export, resource, &1["edge"]))

    assert targets != []
    references = targets |> Enum.map(&relative_reference(resource, &1)) |> Enum.uniq()

    href =
      case actual_reference do
        nil ->
          assert [only] = references
          only

        actual ->
          assert actual in references
          actual
      end

    source = String.replace(source, ~s|"./#{child}.js"|, ~s|"#{href}"|)

    if goal == :script do
      {:ok, hidden_url} = URL.resolve("./hidden.js", resource["url"])
      hidden = reference_target(export, resource, hidden_url)
      String.replace(source, ~S|".\/hidden.js"|, ~s|"#{relative_reference(resource, hidden)}"|)
    else
      source
    end
  end
end
