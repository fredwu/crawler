defmodule Crawler.Linker.SnapshotComponentTest do
  use ExUnit.Case, async: false

  import Crawler.SnapshotHelpers, only: [saved_artifact: 2]
  import Crawler.TestHelpers

  alias Crawler.ManagedSnapshotHelpers, as: Managed
  alias Crawler.Snapper

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
  end

  test "long queries, directory names, case and Unicode retain distinct identities" do
    directory = String.duplicate("A", 80)
    composed = String.duplicate("é", 150)
    decomposed = String.duplicate("e" <> <<0x0301::utf8>>, 150)

    urls = [
      "http://ex.com/app.css?q=#{String.duplicate("A", 50)}",
      "http://ex.com/app.css?q=#{String.duplicate("a", 50)}",
      "http://ex.com/app.css?q=#{String.duplicate("A", 49)}B",
      "http://ex.com/app.css?q=#{String.duplicate("%26", 100)}",
      "http://ex.com/#{directory}/one.bin",
      "http://ex.com/#{directory}/two.bin",
      "http://ex.com/#{String.downcase(directory)}/one.bin",
      "http://ex.com/#{composed}",
      "http://ex.com/#{decomposed}",
      "http://ex.com/#{String.duplicate("中", 100)}",
      "http://#{String.duplicate("U", 60)}@ex.com/one.bin"
    ]

    identities = Enum.map(urls, &Crawler.URL.canonical/1)
    assert length(Enum.uniq(identities)) == length(urls)
  end

  test "literal digest names cannot collide with bounded file or directory identities" do
    directory_url = "http://ex.com/#{String.duplicate("A", 100)}"

    literal_directory_url =
      "http://ex.com/__sha256_dc07f38ea9c801dd1c61a4a09e489286e55bb100a44e04d825ab5d91d185c3ff"

    file_url = "http://ex.com/#{String.duplicate("A", 100)}.CSS"

    literal_file_url =
      "http://ex.com/__sha256_59665af2a8606fe27add8038b837464a10b6de3a282a99cf659fca8a24ca3ab0.css"

    root = tmp("snapshot-digest-names")
    urls = [directory_url, literal_directory_url, file_url, literal_file_url]

    public_ids = [
      "component0000000000000001",
      "component0000000000000002",
      "component0000000000000003",
      "component0000000000000004"
    ]

    artifacts =
      for {{url, public_id}, index} <- Enum.with_index(Enum.zip(urls, public_ids)) do
        body = "BODY-#{index}"

        assert {:ok, artifact} =
                 Snapper.snap(body, %{
                   url: url,
                   save_to: root,
                   content_type: "text/plain",
                   public_id: public_id
                 })

        {artifact, index}
      end

    paths = Enum.map(artifacts, fn {artifact, _index} -> artifact.path end)
    assert length(Enum.uniq(paths)) == length(paths)

    for {artifact, index} <- artifacts do
      body = "BODY-#{index}"
      assert File.read!(saved_artifact(root, artifact)) == body
    end
  end

  test "saved long references open exact bodies and retain stylesheet MIME types" do
    root = tmp("snapshot-long-links")
    page = "http://ex.com/page"

    targets = [
      {"http://ex.com/app.css?q=#{String.duplicate("A", 50)}", "text/css",
       ".upper { color: red }"},
      {"http://ex.com/#{String.duplicate("A", 80)}.CSS", "text/css", ".case { color: blue }"},
      {"http://ex.com/#{String.duplicate("é", 150)}/file.bin", "application/octet-stream",
       <<0xFF, 0xE9>>},
      {"http://ex.com/#{String.duplicate("a%2F", 80)}.bin", "application/octet-stream",
       <<0x89, 0xE9>>}
    ]

    html = Enum.map_join(targets, "", fn {url, _type, _body} -> ~s(<a href="#{url}">open</a>) end)

    export =
      managed_export(
        root,
        page,
        html,
        Enum.map(targets, fn {url, type, body} -> {url, body, type} end)
      )

    source = Managed.resource_for_url(export, page)

    hrefs =
      export
      |> Managed.read_resource(source)
      |> Floki.parse_document!()
      |> Floki.attribute("a", "href")

    assert length(hrefs) == length(targets)

    static = Plug.Static.init(at: "/", from: export.root)

    for {{href, {url, type, body}}, index} <- Enum.with_index(Enum.zip(hrefs, targets)) do
      target = Managed.edge_target(export, source, index)
      assert target["url"] == Crawler.URL.normalize(url)
      Managed.assert_opens(export, source, target, href)
      assert_components_fit(target["path"])
      assert Managed.read_resource(export, target) == body
      response = :get |> Plug.Test.conn("/" <> target["path"]) |> Plug.Static.call(static)
      assert response.status == 200
      assert Plug.Conn.get_resp_header(response, "content-type") == [type]
      assert response.resp_body == body
    end
  end

  test "standalone public ID acknowledgements contain long URL artifacts and serve exact bytes" do
    root = tmp("standalone-long-url-ack-serving")
    static = Plug.Static.init(at: "/", from: root)

    targets = [
      {"standalone000000000003001", "http://ex.com/app.css?q=#{String.duplicate("A", 50)}",
       "text/css", ".css", ".upper { color: red }"},
      {"standalone000000000003002", "http://ex.com/#{String.duplicate("A", 80)}.CSS", "text/css",
       ".css", ".case { color: blue }"},
      {"standalone000000000003003", "http://ex.com/#{String.duplicate("é", 150)}/file.bin",
       "application/octet-stream", ".bin", <<0xFF, 0xE9>>},
      {"standalone000000000003004", "http://ex.com/#{String.duplicate("a%2F", 80)}.bin",
       "application/octet-stream", ".bin", <<0x89, 0xE9>>}
    ]

    for {id, url, type, suffix, body} <- targets do
      assert {:ok, %{public_id: ^id, path: path} = artifact} =
               Snapper.snap(body, %{
                 public_id: id,
                 url: url,
                 save_to: root,
                 content_type: type
               })

      assert path == "resources/" <> id <> suffix
      assert byte_size(path) <= 240
      assert Enum.all?(String.split(path, "/"), &(byte_size(&1) <= 128))

      assert String.starts_with?(
               Path.expand(saved_artifact(root, artifact)),
               Path.expand(root) <> "/"
             )

      assert File.read!(saved_artifact(root, artifact)) == body
      response = :get |> Plug.Test.conn("/" <> path) |> Plug.Static.call(static)
      assert response.status == 200
      assert Plug.Conn.get_resp_header(response, "content-type") == [type]
      assert response.resp_body == body
    end
  end

  test "file-looking directories coexist with files and literal directory markers" do
    root = tmp("snapshot-file-directories")
    page = "http://ex.com/page"
    long = String.duplicate("A", 80) <> ".JS"

    urls = [
      "http://ex.com/app.js",
      "http://ex.com/app.js//",
      "http://ex.com/app.js///",
      "http://ex.com/app.js/child",
      "http://ex.com/app.JS/child",
      "http://ex.com/__dir_app.js",
      "http://ex.com/__dir_app.js/child",
      "http://ex.com/#{long}",
      "http://ex.com/#{long}/child"
    ]

    targets = for {url, index} <- Enum.with_index(urls), do: {url, "BODY-#{index}", "text/plain"}
    html = Enum.map_join(urls, "", &~s(<a href="#{&1}">open</a>))
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
        assert target["url"] == Crawler.URL.normalize(url)
        Managed.assert_opens(export, source, target, href)
        assert_components_fit(target["path"])
        assert Managed.read_resource(export, target) == "BODY-#{index}"
        target["path"]
      end

    assert length(Enum.uniq(resources)) == length(urls)

    assert Crawler.URL.canonical("http://ex.com/app.js/") ==
             Crawler.URL.canonical("http://ex.com/app.js")
  end

  defp assert_components_fit(path) do
    assert Enum.all?(String.split(path, "/"), &(byte_size(&1) <= 255))
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

    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      key = conn |> Plug.Conn.request_url() |> route_key.()
      Crawler.RequestLog.record(requests, key)
      {body, type} = Map.fetch!(routes, key)
      conn |> Plug.Conn.put_resp_header("content-type", type) |> Plug.Conn.resp(200, body)
    end)

    assert {:ok, opts} =
             Crawler.crawl(page,
               scope: Crawler.TestHelpers.unique_scope("managed-snapshot"),
               save_to: root,
               store: nil,
               workers: 1,
               max_body: 1_048_576,
               max_analysis_bytes: 16_777_216,
               max_css_work: 5_000,
               max_css_pictures: 1_000,
               max_manifest_bytes: 16 * 1024 * 1024,
               max_depths: 3,
               respect_robots: false,
               req_options: [plug: {Req.Test, name}, retry: false]
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
