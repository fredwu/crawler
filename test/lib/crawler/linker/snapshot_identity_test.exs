defmodule Crawler.Linker.SnapshotIdentityTest do
  use ExUnit.Case, async: false

  alias Crawler.ManagedSnapshotHelpers, as: Managed
  alias Crawler.URL

  test "canonically equivalent precomposed characters retain separate files" do
    root =
      Crawler.TestHelpers.tmp(
        "snapshot-identity-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    pairs = [
      {0x03AC, 0x1F71, "001f71"},
      {0x8C48, 0xF900, "00f900"}
    ]

    for {stable, changing, _hex} <- pairs do
      stable_url = "http://ex.com/" <> <<stable::utf8>>
      changing_url = "http://ex.com/" <> <<changing::utf8>>

      refute URL.normalize(stable_url) == URL.normalize(changing_url)
      assert String.normalize(stable_url, :nfc) == String.normalize(changing_url, :nfc)
    end

    targets =
      for {stable, changing, hex} <- pairs,
          {url, body} <- [
            {"http://ex.com/" <> <<stable::utf8>>, "STABLE"},
            {"http://ex.com/" <> <<changing::utf8>>, "CHANGING"},
            {"http://ex.com/__u_#{hex}", "LITERAL"}
          ],
          do: {url, body, "text/plain"}

    page = "http://ex.com/page"
    source = Enum.map_join(targets, "", fn {url, _, _} -> ~s(<a href="#{url}">open</a>) end)
    export = managed_export(root, page, source, targets)
    from = Managed.resource_for_url(export, page)

    hrefs =
      export
      |> Managed.read_resource(from)
      |> Floki.parse_document!()
      |> Floki.attribute("a", "href")

    assert length(hrefs) == length(targets)

    paths =
      for {{href, {url, body, _}}, index} <- Enum.with_index(Enum.zip(hrefs, targets)) do
        to = Managed.edge_target(export, from, index)
        assert to["url"] == URL.normalize(url)
        Managed.assert_opens(export, from, to, href)
        assert Managed.read_resource(export, to) == body
        to["path"]
      end

    folded = Enum.map(paths, &(&1 |> String.normalize(:nfd) |> :string.casefold()))
    assert length(Enum.uniq(folded)) == length(targets)
  end

  defp managed_export(root, page, source, targets) do
    File.rmdir!(root)
    root = root <> "-#{System.pid()}-#{System.unique_integer([:positive])}"
    requests = Crawler.RequestLog.new()

    route_key = fn url ->
      uri = url |> Crawler.URL.canonical() |> URI.parse()
      URI.to_string(%{uri | query: uri.query || ""})
    end

    routes =
      Map.new([{page, source, "text/html"} | targets], fn {url, body, type} ->
        {route_key.(url), {body, type}}
      end)

    plug = fn conn ->
      key = conn |> Plug.Conn.request_url() |> route_key.()
      Crawler.RequestLog.record(requests, key)
      {body, type} = Map.fetch!(routes, key)
      conn |> Plug.Conn.put_resp_header("content-type", type) |> Plug.Conn.resp(200, body)
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
               req_options: [plug: plug, retry: false]
             )

    on_exit(fn ->
      Crawler.stop(opts)
      File.rm_rf!(root)
    end)

    export = Managed.ready_export(opts)

    assert Crawler.RequestLog.frequencies(requests) ==
             Map.new(routes, fn {url, _} -> {url, 1} end)

    export
  end
end
