defmodule Crawler.Linker.SnapshotExtensionTest do
  use ExUnit.Case, async: false

  import Crawler.SnapshotHelpers, only: [saved_artifact: 2]
  import Crawler.TestHelpers

  alias Crawler.ManagedSnapshotHelpers, as: Managed
  alias Crawler.Snapper

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  test "case-sensitive asset URLs retain distinct canonical identities" do
    for extensions <- [~w(CSS CsS css), ~w(JS Js js), ~w(HTML Html html)] do
      identities =
        for extension <- extensions,
            query <- ["", "?", "?v=1", "?v=1&x=2"],
            do: Crawler.URL.canonical("http://ex.com/app.#{extension}#{query}")

      assert length(Enum.uniq(identities)) == length(identities)
    end
  end

  test "extension suffixes do not collide with longer filenames or literal markers" do
    urls = [
      "http://ex.com/app.CSS",
      "http://ex.com/app.css",
      "http://ex.com/app.CSS.css",
      "http://ex.com/app.CSS__ext_.css",
      "http://ex.com/app.__u_c__u_s__u_s__ext_.css",
      "http://ex.com/app.__u_c__u_s__u_s.css"
    ]

    identities = Enum.map(urls, &Crawler.URL.canonical/1)
    assert length(Enum.uniq(identities)) == length(urls)
  end

  test "saved uppercase and mixed-case assets serve their body with the correct MIME type" do
    root = tmp("snapshot-extension-serving")
    page = "http://ex.com/page"

    targets = [
      {"http://ex.com/app.CSS", "body { color: red }", "text/css"},
      {"http://ex.com/app.css", "body { color: blue }", "text/css"},
      {"http://ex.com/app.CsS?v=1&x=2", "body { color: green }", "text/css"},
      {"http://ex.com/app.JS", "export const upper = 1", "text/javascript"},
      {"http://ex.com/app.Js?v=1", "export const mixed = 1", "text/javascript"},
      {"http://ex.com/app.HTML", "<p>UPPER</p>", "text/html"},
      {"http://ex.com/app.Html?", "<p>MIXED</p>", "text/html"}
    ]

    html = Enum.map_join(targets, "", fn {url, _body, _type} -> ~s(<a href="#{url}"></a>) end)
    export = managed_export(root, page, html, targets)
    source = Managed.resource_for_url(export, page)

    hrefs =
      export
      |> Managed.read_resource(source)
      |> Floki.parse_document!()
      |> Floki.attribute("a", "href")

    assert length(hrefs) == length(targets)
    static = Plug.Static.init(at: "/", from: export.root)

    for {{href, {url, body, type}}, index} <- Enum.with_index(Enum.zip(hrefs, targets)) do
      target = Managed.edge_target(export, source, index)
      assert target["url"] == Crawler.URL.normalize(url)
      Managed.assert_opens(export, source, target, href)

      response =
        :get
        |> Plug.Test.conn("/" <> target["path"])
        |> Plug.Static.call(static)

      assert response.status == 200
      expected = if type == "text/html", do: @utf8_bom <> body, else: body
      assert response.resp_body == expected
      assert Plug.Conn.get_resp_header(response, "content-type") == [type]
    end
  end

  test "standalone public ID acknowledgements serve response-aware asset types and exact bodies" do
    root = tmp("standalone-extension-ack-serving")
    static = Plug.Static.init(at: "/", from: root)

    targets = [
      {"standalone000000000002001", "http://ex.com/app.CSS", "body { color: red }", "text/css",
       ".css"},
      {"standalone000000000002002", "http://ex.com/app.css", "body { color: blue }", "text/css",
       ".css"},
      {"standalone000000000002003", "http://ex.com/app.CsS?v=1&x=2", "body { color: green }",
       "text/css", ".css"},
      {"standalone000000000002004", "http://ex.com/app.JS", "export const upper = 1",
       "text/javascript", ".js"},
      {"standalone000000000002005", "http://ex.com/app.Js?v=1", "export const mixed = 1",
       "text/javascript", ".js"},
      {"standalone000000000002006", "http://ex.com/app.HTML", "<p>UPPER</p>", "text/html",
       ".html"},
      {"standalone000000000002007", "http://ex.com/app.Html?", "<p>MIXED</p>", "text/html",
       ".html"}
    ]

    for {id, url, body, type, suffix} <- targets do
      assert {:ok, %{public_id: ^id, path: path} = artifact} =
               Snapper.snap(body, %{
                 public_id: id,
                 url: url,
                 referrer_url: url,
                 save_to: root,
                 content_type: type,
                 html_tag: "a",
                 assets: ["css", "js"],
                 depth: 1,
                 max_depths: 2
               })

      assert path == "resources/" <> id <> suffix
      expected = if type == "text/html", do: @utf8_bom <> body, else: body
      assert File.read!(saved_artifact(root, artifact)) == expected
      response = :get |> Plug.Test.conn("/" <> path) |> Plug.Static.call(static)
      assert response.status == 200
      assert Plug.Conn.get_resp_header(response, "content-type") == [type]
      assert response.resp_body == expected
    end
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
