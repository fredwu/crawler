defmodule Crawler.Linker.SnapshotDownloadTest do
  use ExUnit.Case, async: false

  import Crawler.SnapshotHelpers, only: [saved_artifact: 2]
  import Crawler.TestHelpers

  alias Crawler.ManagedSnapshotHelpers, as: Managed
  alias Crawler.Snapper

  test "document download links serve their exact filename, MIME type, and bytes" do
    root = tmp("snapshot-document-downloads")
    page = "http://ex.com/downloads"
    docx_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    xlsx_type = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

    targets = [
      {"http://ex.com/report.docx", "report.docx", docx_type, <<0x50, 0x4B, 0x03, 0x04, 0xE9>>},
      {"http://ex.com/report.xlsx", "report.xlsx", xlsx_type, <<0x50, 0x4B, 0x03, 0x04, 0xFF>>}
    ]

    html =
      Enum.map_join(targets, "", fn {url, _filename, _type, _body} ->
        ~s(<a href="#{url}">Download</a>)
      end)

    export =
      managed_export(
        root,
        page,
        html,
        Enum.map(targets, fn {url, _filename, type, body} -> {url, body, type} end)
      )

    source = Managed.resource_for_url(export, page)
    links = export |> Managed.read_resource(source) |> Floki.parse_document!() |> Floki.find("a")
    assert length(links) == length(targets)
    static = Plug.Static.init(at: "/", from: export.root)

    for {{link, {url, filename, type, body}}, index} <- Enum.with_index(Enum.zip(links, targets)) do
      [href] = Floki.attribute(link, "href")
      target = Managed.edge_target(export, source, index)
      assert target["url"] == Crawler.URL.normalize(url)
      Managed.assert_opens(export, source, target, href)
      relative = target["path"]
      assert Path.basename(relative) == target["id"] <> Path.extname(filename)
      assert Managed.read_resource(export, target) == body

      response =
        :get
        |> Plug.Test.conn(
          "/" <> URI.encode(relative, fn byte -> byte == ?/ or URI.char_unreserved?(byte) end)
        )
        |> Plug.Static.call(static)

      assert response.status == 200
      assert Plug.Conn.get_resp_header(response, "content-type") == [type]
      assert response.resp_body == body

      download = tmp("snapshot-download-copies", Path.basename(relative))
      File.write!(download, response.resp_body)
      assert Path.basename(download) == target["id"] <> Path.extname(filename)
      assert File.read!(download) == body
    end
  end

  test "standalone public ID acknowledgements serve document MIME types and exact download bytes" do
    root = tmp("standalone-document-ack-serving")
    docx_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    xlsx_type = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    static = Plug.Static.init(at: "/", from: root)

    targets = [
      {"standalone000000000001001", "http://ex.com/report.docx", docx_type, ".docx",
       <<0x50, 0x4B, 0x03, 0x04, 0xE9>>},
      {"standalone000000000001002", "http://ex.com/report.xlsx", xlsx_type, ".xlsx",
       <<0x50, 0x4B, 0x03, 0x04, 0xFF>>}
    ]

    for {id, url, type, suffix, body} <- targets do
      assert {:ok, %{public_id: ^id, path: path} = artifact} =
               Snapper.snap(body, %{
                 public_id: id,
                 url: url,
                 content_type: type,
                 save_to: root
               })

      assert map_size(artifact) == 2
      assert path == "resources/" <> id <> suffix
      assert File.read!(saved_artifact(root, artifact)) == body

      assert String.starts_with?(
               Path.expand(saved_artifact(root, artifact)),
               Path.expand(root) <> "/"
             )

      response = :get |> Plug.Test.conn("/" <> path) |> Plug.Static.call(static)
      assert response.status == 200
      assert Plug.Conn.get_resp_header(response, "content-type") == [type]
      assert response.resp_body == body

      download = tmp("standalone-document-ack-copies", Path.basename(path))
      File.write!(download, response.resp_body)
      assert Path.basename(download) == id <> suffix
      assert File.read!(download) == body
    end
  end

  test "document suffixes retain query, case, and escaped marker identities" do
    urls = [
      "http://ex.com/report.docx",
      "http://ex.com/report.docx?",
      "http://ex.com/report.docx?q=1&x=2",
      "http://ex.com/report.docx?q=1%26x=2",
      "http://ex.com/report.DOCX",
      "http://ex.com/report.Docx",
      "http://ex.com/report__q_q=1.docx",
      "http://ex.com/report.docx?q=1",
      "http://ex.com/report.DOCX.docx"
    ]

    identities = Enum.map(urls, &Crawler.URL.canonical/1)
    assert length(Enum.uniq(identities)) == length(urls)
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
