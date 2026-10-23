defmodule Crawler.Linker.SnapshotTest do
  use ExUnit.Case, async: false

  import Crawler.SnapshotHelpers, only: [saved_artifact: 2]
  import Crawler.TestHelpers

  alias Crawler.Linker
  alias Crawler.ManagedSnapshotHelpers, as: Managed
  alias Crawler.Snapper
  alias Crawler.URL

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
  end

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  test "parent links resolve to their canonical target URLs" do
    page = "http://example.com/blog/post"
    about = "http://example.com/about"
    css = "http://example.com/css/app.css"
    image = "http://example.com/images/a.png"
    dotted = "http://example.com/a/../../about"

    assert_expands(page, "../../about", about)
    assert_expands(page, dotted, about)
    assert_expands(css, "../../images/a.png", image)
    assert_expands("http://example.com/app.css", "../images/a.png", image)
  end

  test "equivalent URLs share one canonical identity" do
    assert URL.canonical("http://Example.com/a/../b") == URL.canonical("http://example.com/b")
    assert URL.canonical("http://example.com/a/./c") == URL.canonical("http://example.com/a/c")
    assert URL.canonical("http://example.com/a#section") == URL.canonical("http://example.com/a")

    refute URL.canonical("http://example.com/a/.../c") == URL.canonical("http://example.com/a/c")
  end

  test "ports, colons, and literal markers retain distinct canonical identities" do
    pairs = [
      {"http://ex.com:8080/a", "http://ex.com-8080/a"},
      {"http://ex.com/foo:bar", "http://ex.com/foo-bar"},
      {"http://ex.com:8080/foo:bar", "http://ex.com/foo__c_bar"},
      {"http://ex.com:8080/a", "http://ex.com__port_8080/a"}
    ]

    for {left, right} <- pairs, do: refute(URL.canonical(left) == URL.canonical(right))
    assert URL.canonical("http://ex.com:80/a") == URL.canonical("http://ex.com/a")
    assert URL.canonical("https://ex.com:443/a") == URL.canonical("https://ex.com/a")
    assert URI.parse(URL.canonical("http://ex.com/a?x=1:2")).query == "x=1:2"
  end

  test "saved links expand to distinct colon and dash files" do
    root = tmp("snapshot-colon")
    page = "http://ex.com/page"
    port = "http://ex.com:8080/a"
    dashed_host = "http://ex.com-8080/a"
    colon = "http://ex.com/foo:bar"
    dashed_path = "http://ex.com/foo-bar"

    html =
      ~s(<a href="#{port}"></a><a href="#{dashed_host}"></a><a href="#{colon}"></a><a href="#{dashed_path}"></a>)

    targets = [
      {port, "PORT", "text/html"},
      {dashed_host, "DASH", "text/html"},
      {colon, "COLON", "text/html"},
      {dashed_path, "HYPHEN", "text/html"}
    ]

    export = managed_export(root, page, html, targets)
    assert_saved_targets(export, page, targets)
  end

  test "empty path segments do not share a file" do
    root = tmp("snapshot-empty")
    page = "http://example.com/page"
    doubled = "http://example.com/a//b"
    plain = "http://example.com/a/b"
    leading = "http://example.com//a"
    normal = "http://example.com/a"
    marker = "http://example.com/a/__e_/b"

    refute URL.canonical(doubled) == URL.canonical(plain)
    refute URL.canonical(leading) == URL.canonical(normal)
    refute URL.canonical(doubled) == URL.canonical(marker)

    targets = [
      {doubled, "DOUBLED", "text/html"},
      {plain, "PLAIN", "text/html"},
      {leading, "LEAD", "text/html"},
      {normal, "NORM", "text/html"},
      {marker, "MARK", "text/html"}
    ]

    html = ~s(<a href="#{doubled}"></a>)
    export = managed_export(root, page, html, targets, [plain, leading, normal, marker])
    from = Managed.resource_for_url(export, page)

    [href] =
      export
      |> Managed.read_resource(from)
      |> Floki.parse_document!()
      |> Floki.attribute("a", "href")

    doubled_resource = Managed.edge_target(export, from, 0)
    Managed.assert_opens(export, from, doubled_resource, href)
    assert Managed.read_resource(export, from) == @utf8_bom <> ~s(<a href="#{href}"></a>)

    paths =
      for {url, body, _} <- targets do
        target =
          if url == doubled, do: doubled_resource, else: Managed.resource_for_url(export, url)

        assert target["url"] == URL.normalize(url)
        assert Managed.read_resource(export, target) == @utf8_bom <> body
        target["path"]
      end

    assert length(Enum.uniq(paths)) == length(targets)
  end

  test "rewritten URLs open distinct saved files after one browser URL decode" do
    root = tmp("snapshot-browser-decoding")
    page = "http://ex.com/page"

    targets = [
      {"http://ex.com/Docs", "CASE", ""},
      {"http://ex.com/__u_docs", "LITERAL CASE", "#part%20one"},
      {"http://ex.com/app.js?q=a&b=c", "QUERY SEPARATOR", ""},
      {"http://ex.com/app.js?q=a%26b=c", "ENCODED QUERY SEPARATOR", ""},
      {"http://ex.com/a/b", "PATH SEPARATOR", ""},
      {"http://ex.com/a%2fb", "ENCODED PATH SEPARATOR", "#section"},
      {"http://ex.com/__index.html", "LITERAL INDEX", ""},
      {"http://ex.com/", "DIRECTORY INDEX", ""},
      {"http://ex.com/café", "UNICODE", "#café"},
      {"http://ex.com/cafe" <> <<0x0301::utf8>>, "COMBINING MARK", ""}
    ]

    html =
      Enum.map_join(targets, "", fn {url, _body, fragment} ->
        ~s(<a href="#{url <> fragment}"></a>)
      end)

    export =
      managed_export(
        root,
        page,
        html,
        Enum.map(targets, fn {url, body, _} -> {url, body, "text/html"} end)
      )

    from = Managed.resource_for_url(export, page)

    hrefs =
      export
      |> Managed.read_resource(from)
      |> Floki.parse_document!()
      |> Floki.attribute("a", "href")

    assert length(hrefs) == length(targets)

    paths =
      for {{href, {url, body, fragment}}, index} <- Enum.with_index(Enum.zip(hrefs, targets)) do
        to = Managed.edge_target(export, from, index)
        assert to["url"] == Crawler.URL.normalize(url)
        expected_suffix = if fragment == "#café", do: "#caf%c3%a9", else: fragment
        Managed.assert_opens(export, from, to, href, expected_suffix)
        assert URI.parse(href).query == nil

        if fragment == "" do
          assert URI.parse(href).fragment == nil
        else
          original_fragment = String.trim_leading(fragment, "#")
          expected_fragment = if fragment == "#café", do: "caf%c3%a9", else: original_fragment
          actual_fragment = URI.parse(href).fragment
          assert actual_fragment == expected_fragment
          assert URI.decode(actual_fragment) == URI.decode(original_fragment)
        end

        assert Managed.read_resource(export, to) == @utf8_bom <> body
        to["path"]
      end

    assert length(Enum.uniq(paths)) == length(targets)
  end

  test "schemes, credentials, empty queries, and literal markers retain URL identities" do
    urls = [
      "http://ex.com/a",
      "https://ex.com/a",
      "https://ex.com:8443/a",
      "http://a:b@ex.com/secret",
      "https://a:b@ex.com:8080/secret",
      "http://ex.com/search?",
      "http://ex.com?",
      "http://ex.com/Docs",
      "http://[::1]/a",
      "http://ex.com__scheme_https/a",
      "http://ex.com/__user_x",
      "http://x@ex.com/__user_x",
      "http://ex.com/search/__index__q_.html"
    ]

    identities = Enum.map(urls, &URL.canonical/1)
    assert length(Enum.uniq(identities)) == length(urls)
    assert URL.canonical("https://ex.com:443/a") == URL.canonical("https://ex.com/a")
  end

  test "case and combining marks retain distinct canonical URLs" do
    pairs = [
      {"http://ex.com/Docs", "http://ex.com/docs"},
      {"http://A:B@ex.com/Docs", "http://a:b@ex.com/docs"},
      {"http://ex.com/search?Q=1", "http://ex.com/search?q=1"},
      {"http://ex.com/" <> <<0x00E9::utf8>>, "http://ex.com/e" <> <<0x0301::utf8>>},
      {"http://ex.com/" <> <<0x0309::utf8>> <> "9", "http://ex.com/" <> <<0x3099::utf8>>}
    ]

    for {left, right} <- pairs, do: refute(URL.canonical(left) == URL.canonical(right))

    assert URL.normalize("http://ex.com/a" <> <<0x036F::utf8>>) ==
             "http://ex.com/a" <> <<0x036F::utf8>>
  end

  test "a literal case or mark marker does not share a file" do
    nfd = "http://ex.com/e" <> <<0x0301::utf8>>

    root = tmp("snapshot-literal-markers")
    docs_artifact = snap_artifact("DOCS", "http://ex.com/Docs", root, "identity0000000000000001")

    case_artifact =
      snap_artifact("CASE", "http://ex.com/__u_docs", root, "identity0000000000000002")

    nfd_artifact = snap_artifact("NFD", nfd, root, "identity0000000000000003")

    mark_artifact =
      snap_artifact("MARK", "http://ex.com/e__m_301", root, "identity0000000000000004")

    assert File.read!(saved_artifact(root, docs_artifact)) == @utf8_bom <> "DOCS"
    assert File.read!(saved_artifact(root, case_artifact)) == @utf8_bom <> "CASE"
    assert File.read!(saved_artifact(root, nfd_artifact)) == @utf8_bom <> "NFD"
    assert File.read!(saved_artifact(root, mark_artifact)) == @utf8_bom <> "MARK"
  end

  test "a decomposed hiragana letter does not share a file with the composed letter" do
    composed = "http://ex.com/" <> <<0x304C::utf8>>
    decomposed = "http://ex.com/" <> <<0x304B::utf8>> <> <<0x3099::utf8>>
    root = tmp("snapshot-hiragana")
    composed_artifact = snap_artifact("COMPOSED", composed, root, "identity0000000000000001")

    decomposed_artifact =
      snap_artifact("DECOMPOSED", decomposed, root, "identity0000000000000002")

    assert File.read!(saved_artifact(root, composed_artifact)) == @utf8_bom <> "COMPOSED"
    assert File.read!(saved_artifact(root, decomposed_artifact)) == @utf8_bom <> "DECOMPOSED"
  end

  test "İ does not share a file with I plus a combining dot" do
    dotted = "http://ex.com/" <> <<0x0130::utf8>>
    split = "http://ex.com/" <> <<0x0049::utf8>> <> <<0x0307::utf8>>
    root = tmp("snapshot-dotted-i")
    dotted_artifact = snap_artifact("DOTTED", dotted, root, "identity0000000000000001")
    split_artifact = snap_artifact("SPLIT", split, root, "identity0000000000000002")
    assert File.read!(saved_artifact(root, dotted_artifact)) == @utf8_bom <> "DOTTED"
    assert File.read!(saved_artifact(root, split_artifact)) == @utf8_bom <> "SPLIT"
  end

  test "a decomposed hangul syllable does not share a file with the composed letter" do
    composed = "http://ex.com/" <> <<0xAC00::utf8>>
    decomposed = "http://ex.com/" <> <<0x1100::utf8>> <> <<0x1161::utf8>>
    root = tmp("snapshot-hangul")
    composed_artifact = snap_artifact("COMPOSED", composed, root, "identity0000000000000001")
    jamo_artifact = snap_artifact("JAMO", decomposed, root, "identity0000000000000002")

    literal_artifact =
      snap_artifact("LITERAL", "http://ex.com/__j_001100", root, "identity0000000000000003")

    assert File.read!(saved_artifact(root, composed_artifact)) == @utf8_bom <> "COMPOSED"
    assert File.read!(saved_artifact(root, jamo_artifact)) == @utf8_bom <> "JAMO"
    assert File.read!(saved_artifact(root, literal_artifact)) == @utf8_bom <> "LITERAL"
  end

  test "letters that share a lowercase form do not share a file" do
    kay = "http://ex.com/K"
    kelvin = "http://ex.com/" <> <<0x212A::utf8>>

    refute URL.canonical(kay) == URL.canonical(kelvin)

    pairs = [
      {0x00C5, "0000c5", 0x212B, "00212b"},
      {0x01C4, "0001c4", 0x01C5, "0001c5"},
      {0x01C7, "0001c7", 0x01C8, "0001c8"},
      {0x01CA, "0001ca", 0x01CB, "0001cb"},
      {0x01F1, "0001f1", 0x01F2, "0001f2"},
      {0x0398, "000398", 0x03F4, "0003f4"},
      {0x03A9, "0003a9", 0x2126, "002126"}
    ]

    for {left, _left_hex, right, _right_hex} <- pairs do
      refute URL.canonical("http://ex.com/" <> <<left::utf8>>) ==
               URL.canonical("http://ex.com/" <> <<right::utf8>>)
    end

    root = tmp("snapshot-case-fold")
    kay_artifact = snap_artifact("K", kay, root, "identity0000000000000001")
    kelvin_artifact = snap_artifact("KELVIN", kelvin, root, "identity0000000000000002")
    assert File.read!(saved_artifact(root, kay_artifact)) == @utf8_bom <> "K"
    assert File.read!(saved_artifact(root, kelvin_artifact)) == @utf8_bom <> "KELVIN"
  end

  test "a casefold that downcase leaves unchanged does not share a file" do
    pairs = [
      {<<0x00DF::utf8>>, "__u_0000df", "ss"},
      {<<0xFB01::utf8>>, "__u_00fb01", "fi"},
      {<<0x00B5::utf8>>, "__u_0000b5", <<0x03BC::utf8>>},
      {<<0x017F::utf8>>, "__u_00017f", "s"},
      {<<0x03C2::utf8>>, "__u_0003c2", <<0x03C3::utf8>>}
    ]

    root = tmp("snapshot-casefold-stable")

    public_ids = [
      {"identity0000000000000001", "identity0000000000000002"},
      {"identity0000000000000003", "identity0000000000000004"},
      {"identity0000000000000005", "identity0000000000000006"},
      {"identity0000000000000007", "identity0000000000000008"},
      {"identity0000000000000009", "identity0000000000000010"}
    ]

    for {{letter, _marker, other}, {public_id, other_id}} <- Enum.zip(pairs, public_ids) do
      url = "http://ex.com/" <> letter
      other_url = "http://ex.com/" <> other

      refute URL.canonical(url) == URL.canonical(other_url)

      letter_artifact = snap_artifact("LETTER", url, root, public_id)
      other_artifact = snap_artifact("OTHER", other_url, root, other_id)
      assert File.read!(saved_artifact(root, letter_artifact)) == @utf8_bom <> "LETTER"
      assert File.read!(saved_artifact(root, other_artifact)) == @utf8_bom <> "OTHER"
    end
  end

  test "a literal query marker does not share a file" do
    literal = "http://ex.com/app__q_v=1.js"
    query = "http://ex.com/app.js?v=1"
    root = tmp("snapshot-query-marker")
    literal_artifact = snap_artifact("LITERAL", literal, root, "identity0000000000000001")
    query_artifact = snap_artifact("QUERY", query, root, "identity0000000000000002")
    assert File.read!(saved_artifact(root, literal_artifact)) == @utf8_bom <> "LITERAL"
    assert File.read!(saved_artifact(root, query_artifact)) == @utf8_bom <> "QUERY"
  end

  test "a byte that is not utf-8 does not share a file with the same character" do
    raw = "http://ex.com/caf" <> <<0xE9>>
    utf8 = "http://ex.com/caf" <> <<0x00E9::utf8>>
    root = tmp("snapshot-latin1")
    raw_artifact = snap_artifact("RAW", raw, root, "identity0000000000000001")
    utf8_artifact = snap_artifact("UTF8", utf8, root, "identity0000000000000002")
    assert File.read!(saved_artifact(root, raw_artifact)) == @utf8_bom <> "RAW"
    assert File.read!(saved_artifact(root, utf8_artifact)) == @utf8_bom <> "UTF8"
  end

  test "distinct identities do not share a file on disk" do
    root = tmp("snapshot-identity")
    nfc = "http://ex.com/" <> <<0x00E9::utf8>>
    nfd = "http://ex.com/e" <> <<0x0301::utf8>>

    pairs = [
      {"http://ex.com/a", "http"},
      {"https://ex.com/a", "https"},
      {"http://a:b@ex.com/secret", "user"},
      {"http://A:B@ex.com/secret", "user-case"},
      {"http://ex.com/secret", "open"},
      {"http://ex.com/search", "bare"},
      {"http://ex.com/search?", "empty"},
      {"http://ex.com/search?q=1", "q"},
      {"http://ex.com/search?Q=1", "Q"},
      {"http://ex.com?", "root-empty"},
      {"http://ex.com", "root"},
      {"http://ex.com/docs", "docs"},
      {"http://ex.com/Docs", "Docs"},
      {nfc, "nfc"},
      {nfd, "nfd"},
      {"http://ex.com/" <> <<0x03AC::utf8>>, "tonos"},
      {"http://ex.com/" <> <<0x1F71::utf8>>, "oxia"}
    ]

    page = "http://ex.com/page"
    html = Enum.map_join(pairs, "", fn {url, _} -> ~s(<a href="#{url}"></a>) end)
    targets = Enum.map(pairs, fn {url, body} -> {url, body, "text/html"} end)
    export = managed_export(root, page, html, targets)
    assert_saved_targets(export, page, targets)
    manifest = Jason.encode!(export.manifest)
    refute manifest =~ "a:b@"
    refute manifest =~ "A:B@"
    refute manifest =~ "__user_"
  end

  defp assert_expands(from_url, link, target_url) do
    assert URL.canonical(Linker.url(from_url, link)) == URL.canonical(target_url)
  end

  defp assert_saved_targets(export, page, targets) do
    from = Managed.resource_for_url(export, page)

    hrefs =
      export
      |> Managed.read_resource(from)
      |> Floki.parse_document!()
      |> Floki.attribute("a", "href")

    assert length(hrefs) == length(targets)

    paths =
      for {{href, {url, body, _type}}, index} <- Enum.with_index(Enum.zip(hrefs, targets)) do
        to = Managed.edge_target(export, from, index)
        assert {:ok, online} = Crawler.Export.Paths.online(url)
        assert to["url"] == online
        Managed.assert_opens(export, from, to, href)
        assert Managed.read_resource(export, to) == @utf8_bom <> body
        to["path"]
      end

    folded = Enum.map(paths, &(&1 |> String.normalize(:nfd) |> :string.casefold()))
    assert length(Enum.uniq(folded)) == length(targets)
  end

  defp snap_artifact(body, url, root, public_id) do
    assert {:ok, artifact} =
             Snapper.snap(body, %{
               url: url,
               referrer_url: url,
               save_to: root,
               public_id: public_id,
               html_tag: "a",
               content_type: "text/html",
               depth: 1,
               max_depths: 2
             })

    artifact
  end

  defp managed_export(root, page, source, targets, extra_urls \\ []) do
    File.rmdir!(root)
    root = root <> "-#{System.pid()}-#{System.unique_integer([:positive])}"
    requests = Crawler.RequestLog.new()

    routes =
      Map.new([{page, source, "text/html"} | targets], fn {url, body, type} ->
        {Crawler.URL.canonical(url), {body, type}}
      end)

    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      key = fixture_route_key(conn, routes)

      Crawler.RequestLog.record(requests, key)
      {body, type} = Map.fetch!(routes, key)
      conn |> Plug.Conn.put_resp_header("content-type", type) |> Plug.Conn.resp(200, body)
    end)

    scope = Crawler.TestHelpers.unique_scope("managed-snapshot")

    queue =
      if extra_urls != [] do
        queue_opts = Crawler.Options.assign_defaults(%{scope: scope, workers: 1})
        assert {:ok, owner} = Crawler.Queue.start_link(queue_opts)
        on_exit(fn -> Crawler.Queue.stop(owner) end)
        feeder = Crawler.Queue.feeder(owner)
        OPQ.pause(feeder)
        assert {:paused, _, _} = GenStage.call(feeder, :info)
        feeder
      end

    assert {:ok, opts} =
             Crawler.crawl(page,
               scope: scope,
               queue: queue,
               save_to: root,
               store: nil,
               workers: 1,
               max_body: 1_048_576,
               max_analysis_bytes: 16_777_216,
               max_manifest_bytes: 16 * 1024 * 1024,
               max_depths: 3,
               respect_robots: false,
               url_filter: Crawler.AllowFilter,
               req_options: [
                 plug: {Req.Test, name},
                 plugins: [&fixture_transport/1],
                 retry: false
               ]
             )

    on_exit(fn ->
      Crawler.stop(opts)
      File.rm_rf!(root)
    end)

    for url <- extra_urls, do: assert({:ok, _} = Crawler.crawl(url, opts))
    if extra_urls != [], do: Crawler.resume(opts)
    export = Managed.ready_export(opts)

    assert Crawler.RequestLog.frequencies(requests) ==
             Map.new(routes, fn {url, _} -> {url, 1} end)

    refute Jason.encode!(export.manifest) =~ "x-crawler-fixture-url"
    export
  end

  defp fixture_route_key(conn, routes) do
    case Plug.Conn.get_req_header(conn, "x-crawler-fixture-url") do
      [url] -> Crawler.URL.canonical(url)
      [] -> fixture_connection_key(conn, routes)
    end
  end

  defp fixture_connection_key(conn, routes) do
    key = conn |> Plug.Conn.request_url() |> Crawler.URL.canonical()

    matches =
      Enum.filter(Map.keys(routes), fn url ->
        uri = URI.parse(url)
        uri = %{uri | userinfo: nil, query: if(uri.query == "", do: nil, else: uri.query)}
        Crawler.URL.canonical(URI.to_string(uri)) == key
      end)

    assert [^key] = matches
    key
  end

  defp fixture_transport(request) do
    Req.Request.append_request_steps(request, fixture_url: &fixture_url/1)
  end

  defp fixture_url(request) do
    Req.Request.put_header(request, "x-crawler-fixture-url", URI.to_string(request.url))
  end
end
