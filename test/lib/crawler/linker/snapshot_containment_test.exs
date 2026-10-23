defmodule Crawler.Linker.SnapshotContainmentTest do
  use ExUnit.Case, async: false

  import Crawler.SnapshotHelpers, only: [saved_artifact: 2]
  import Crawler.TestHelpers, only: [tmp: 1]

  alias Crawler.ManagedSnapshotHelpers, as: Managed
  alias Crawler.Snapper
  alias Crawler.URL

  test "encoded dot hosts share identities while saved files stay within the archive" do
    root = tmp("snapshot-dot-hosts/archive")
    page = "http://example.com/index.html"

    groups = [
      ["http://./a", "http://%2e/a"],
      ["http://../a", "http://%2e%2e/a"]
    ]

    identities = Enum.map(groups, fn [url | _] -> URL.canonical(url) end)
    assert length(Enum.uniq(identities)) == length(groups)

    for [canonical | _] = spellings <- groups, url <- spellings do
      assert URL.normalize(url) == canonical
      assert URL.canonical(url) == URL.canonical(canonical)
    end

    urls = List.flatten(groups)
    html = Enum.map_join(urls, "", &~s(<a href="#{&1}">open</a>))
    targets = for [canonical | _] <- groups, do: {canonical, canonical, "text/plain"}
    export = managed_export(root, page, html, targets)
    source = Managed.resource_for_url(export, page)

    hrefs =
      export
      |> Managed.read_resource(source)
      |> Floki.parse_document!()
      |> Floki.attribute("a", "href")

    assert length(hrefs) == length(urls)

    resources =
      for {{href, url}, index} <- Enum.with_index(Enum.zip(hrefs, urls)) do
        target = Managed.edge_target(export, source, index)
        assert target["url"] == URL.normalize(url)
        Managed.assert_opens(export, source, target, href)
        assert Managed.read_resource(export, target) == URL.normalize(url)
        refute Enum.any?(String.split(target["path"], "/"), &(&1 in [".", ".."]))
        target["url"]
      end

    assert length(Enum.uniq(resources)) == length(groups)
  end

  test "standalone public ID acknowledgements keep encoded dot-host artifacts within the root" do
    root = tmp("standalone-dot-host-ack-containment/archive")

    targets = [
      {"standalone000000000004001", "http://./a", "http://./a"},
      {"standalone000000000004002", "http://%2e/a", "http://./a"},
      {"standalone000000000004003", "http://../a", "http://../a"},
      {"standalone000000000004004", "http://%2e%2e/a", "http://../a"}
    ]

    paths =
      for {id, url, canonical} <- targets do
        assert URL.normalize(url) == canonical
        assert URL.canonical(url) == URL.canonical(canonical)

        assert {:ok, %{public_id: ^id, path: path} = artifact} =
                 Snapper.snap(canonical, %{
                   public_id: id,
                   url: url,
                   referrer_url: url,
                   save_to: root,
                   content_type: "text/plain"
                 })

        assert path == "resources/" <> id <> ".txt"

        assert String.starts_with?(
                 Path.expand(saved_artifact(root, artifact)),
                 Path.expand(root) <> "/"
               )

        refute Enum.any?(String.split(path, "/"), &(&1 in [".", ".."]))
        assert File.read!(saved_artifact(root, artifact)) == canonical
        path
      end

    assert length(Enum.uniq(paths)) == length(targets)
  end

  defp managed_export(root, page, source, targets) do
    File.rmdir!(root)
    root = root <> "-#{System.pid()}-#{System.unique_integer([:positive])}"
    requests = Crawler.RequestLog.new()

    routes =
      Map.new([{page, source, "text/html"} | targets], fn {url, body, type} ->
        {Crawler.URL.canonical(url), {body, type}}
      end)

    adapter = fn request ->
      key = request.url |> URI.to_string() |> Crawler.URL.canonical()
      Crawler.RequestLog.record(requests, key)
      {body, type} = Map.fetch!(routes, key)
      {request, Req.Response.new(status: 200, headers: [{"content-type", type}], body: body)}
    end

    assert {:ok, opts} =
             Crawler.crawl(page,
               scope: Crawler.TestHelpers.unique_scope("managed-snapshot"),
               save_to: root,
               store: nil,
               workers: 1,
               max_body: 1_048_576,
               max_analysis_bytes: 16_777_216,
               max_depths: 3,
               respect_robots: false,
               url_filter: Crawler.AllowFilter,
               req_options: [adapter: adapter, retry: false]
             )

    on_exit(fn ->
      Crawler.stop(opts)
      File.rm_rf!(root)
    end)

    export = Managed.ready_export(opts)

    assert Crawler.RequestLog.frequencies(requests) ==
             Map.new(routes, fn {url, _} ->
               {url, if(url == Crawler.URL.canonical(page), do: 1, else: 2)}
             end)

    export
  end
end
