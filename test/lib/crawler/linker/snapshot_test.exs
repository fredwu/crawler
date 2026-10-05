defmodule Crawler.Linker.SnapshotTest do
  use ExUnit.Case, async: true

  import Crawler.SnapshotHelpers, only: [link_path: 1]
  import Crawler.TestHelpers

  alias Crawler.Linker
  alias Crawler.Linker.Snapshot
  alias Crawler.Snapper

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  test "parent links expand to the file that was saved" do
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

  test "equivalent urls share one snapshot path" do
    assert Snapshot.path("http://Example.com/a/../b") == Snapshot.path("http://example.com/b")
    assert Snapshot.path("http://example.com/a/./c") == Snapshot.path("http://example.com/a/c")
    assert Snapshot.path("http://example.com/a#section") == Snapshot.path("http://example.com/a")

    refute Snapshot.path("http://example.com/a/.../c") == Snapshot.path("http://example.com/a/c")
  end

  test "a colon does not share a file with a dash" do
    port = Snapshot.path("http://ex.com:8080/a")
    dashed_host = Snapshot.path("http://ex.com-8080/a")
    colon = Snapshot.path("http://ex.com/foo:bar")
    dashed_path = Snapshot.path("http://ex.com/foo-bar")

    assert port != dashed_host
    assert colon != dashed_path
    refute port =~ ":"
    refute colon =~ ":"
    assert port =~ "ex.com__port_8080/a/__index.html"

    assert Snapshot.path("http://ex.com:8080/foo:bar") ==
             "ex.com__port_8080/foo__c_bar/__index.html"

    assert colon =~ "foo__c_bar"
    assert Snapshot.path("http://ex.com:80/a") == Snapshot.path("http://ex.com/a")
    assert Snapshot.path("https://ex.com:443/a") == Snapshot.path("https://ex.com/a")
    refute Snapshot.path("http://ex.com:80/a") =~ "__port_"
    assert Snapshot.path("http://ex.com/foo__c_bar") =~ "foo__c%5fbar"
    assert Snapshot.path("http://ex.com__port_8080/a") =~ "ex.com__port%5f8080"
    refute Snapshot.path("http://ex.com/a?x=1:2") =~ ":"
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

    snap(html, page, root)
    snap("PORT", port, root)
    snap("DASH", dashed_host, root)
    snap("COLON", colon, root)
    snap("HYPHEN", dashed_path, root)

    assert File.read!(file(root, port)) == @utf8_bom <> "PORT"
    assert File.read!(file(root, dashed_host)) == @utf8_bom <> "DASH"
    assert File.read!(file(root, colon)) == @utf8_bom <> "COLON"
    assert File.read!(file(root, dashed_path)) == @utf8_bom <> "HYPHEN"

    saved = File.read!(file(root, page))
    assert_saved_expands(saved, page, port, root)
    assert_saved_expands(saved, page, dashed_host, root)
    assert_saved_expands(saved, page, colon, root)
    assert_saved_expands(saved, page, dashed_path, root)
  end

  test "empty path segments do not share a file" do
    root = tmp("snapshot-empty")
    page = "http://example.com/page"
    doubled = "http://example.com/a//b"
    plain = "http://example.com/a/b"
    leading = "http://example.com//a"
    normal = "http://example.com/a"
    marker = "http://example.com/a/__e_/b"

    assert Snapshot.path(doubled) != Snapshot.path(plain)
    assert Snapshot.path(leading) != Snapshot.path(normal)
    assert Snapshot.path(doubled) != Snapshot.path(marker)
    refute Snapshot.path(doubled) =~ "//"
    assert Snapshot.path(doubled) =~ "__e_"

    snap("PAGE", page, root)
    snap("DOUBLED", doubled, root)
    snap("PLAIN", plain, root)
    snap("LEAD", leading, root)
    snap("NORM", normal, root)
    snap("MARK", marker, root)
    snap(~s(<a href="#{doubled}"></a>), page, root)

    assert File.read!(file(root, doubled)) == @utf8_bom <> "DOUBLED"
    assert File.read!(file(root, plain)) == @utf8_bom <> "PLAIN"
    assert File.read!(file(root, leading)) == @utf8_bom <> "LEAD"
    assert File.read!(file(root, normal)) == @utf8_bom <> "NORM"
    assert File.read!(file(root, marker)) == @utf8_bom <> "MARK"
    assert_saved_expands(File.read!(file(root, page)), page, doubled, root)
  end

  test "keeps the fragment on the offline link" do
    href = Linker.offline_link("http://example.com/blog/post", "post.html?q=1#section")

    assert String.ends_with?(href, "#section")
    assert href =~ "__q_"
    refute href =~ "post.html?q=1#section"
  end

  test "offline URL references escape literal filesystem percent signs" do
    page = "http://ex.com/page"

    assert Linker.offline_url(page, "http://ex.com/__u_docs") ==
             "http://ex.com/__u%255fdocs/__index.html"

    assert Linker.offline_url(page, "http://ex.com/app.js?q=1&x=2") ==
             "http://ex.com/app__q_q%3D1%2526x%3D2.js"

    assert Snapshot.path("http://ex.com/__u_docs") == "ex.com/__u%5fdocs/__index.html"
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

    Enum.each(targets, fn {url, body, _fragment} -> snap(body, url, root) end)

    html =
      Enum.map_join(targets, "", fn {url, _body, fragment} ->
        ~s(<a href="#{url <> fragment}"></a>)
      end)

    snap(html, page, root)

    hrefs =
      root
      |> file(page)
      |> File.read!()
      |> Floki.parse_document!()
      |> Floki.attribute("a", "href")

    assert length(hrefs) == length(targets)

    for {href, {url, body, fragment}} <- Enum.zip(hrefs, targets) do
      assert href == Linker.offline_link(page, url <> fragment)
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

      opened = Path.expand(link_path(href), Path.dirname(file(root, page)))
      assert opened == Path.expand(file(root, url))
      assert File.read!(opened) == @utf8_bom <> body
    end
  end

  test "https, userinfo, and a bare question mark stay in the file path" do
    assert Snapshot.path("http://ex.com/a") == "ex.com/a/__index.html"
    assert Snapshot.path("https://ex.com/a") == "ex.com__scheme_https/a/__index.html"
    assert Snapshot.path("https://ex.com:443/a") == "ex.com__scheme_https/a/__index.html"

    assert Snapshot.path("https://ex.com:8443/a") ==
             "ex.com__port_8443__scheme_https/a/__index.html"

    assert Snapshot.path("http://a:b@ex.com/secret") ==
             "ex.com__user_a%3ab/secret/__index.html"

    assert Snapshot.path("https://a:b@ex.com:8080/secret") ==
             "ex.com__user_a%3ab__port_8080__scheme_https/secret/__index.html"

    assert Snapshot.path("http://ex.com/search?") == "ex.com/search/__index__q_.html"
    assert Snapshot.path("http://ex.com?") == "ex.com/__index__q_.html"
    assert Snapshot.path("http://ex.com/Docs") == "ex.com/__u_docs/__index.html"
    assert Snapshot.path("http://[::1]/a") == "__c___c_1/a/__index.html"

    literal_scheme = Snapshot.path("http://ex.com__scheme_https/a")
    assert literal_scheme == "ex.com__scheme%5fhttps/a/__index.html"
    refute Snapshot.path("https://ex.com/a") == literal_scheme

    assert Snapshot.path("http://ex.com/__user_x") == "ex.com/__user%5fx/__index.html"
    refute Snapshot.path("http://x@ex.com/__user_x") == Snapshot.path("http://ex.com/__user_x")

    refute Snapshot.path("http://ex.com/search?") ==
             Snapshot.path("http://ex.com/search/__index__q_.html")
  end

  test "case and combining marks do not share a case-folded path" do
    docs = Snapshot.path("http://ex.com/Docs")
    lower = Snapshot.path("http://ex.com/docs")
    assert docs != lower
    refute String.downcase(docs) == String.downcase(lower)

    user = Snapshot.path("http://A:B@ex.com/Docs")
    user_lower = Snapshot.path("http://a:b@ex.com/docs")
    assert user != user_lower
    refute String.downcase(user) == String.downcase(user_lower)

    query = Snapshot.path("http://ex.com/search?Q=1")
    query_lower = Snapshot.path("http://ex.com/search?q=1")
    assert query != query_lower
    refute String.downcase(query) == String.downcase(query_lower)

    nfc = "http://ex.com/" <> <<0x00E9::utf8>>
    nfd = "http://ex.com/e" <> <<0x0301::utf8>>
    nfd_path = Snapshot.path(nfd)
    assert Snapshot.path(nfc) != nfd_path
    refute String.downcase(Snapshot.path(nfc)) == String.downcase(nfd_path)
    assert nfd_path =~ "__m_000301"
    refute nfd_path =~ <<0x0301::utf8>>

    marked = Snapshot.path("http://ex.com/a" <> <<0x036F::utf8>>)
    assert marked =~ "__m_00036f"
    refute marked =~ "__m_36F"

    short = Snapshot.path("http://ex.com/" <> <<0x0309::utf8>> <> "9")
    voiced = Snapshot.path("http://ex.com/" <> <<0x3099::utf8>>)
    assert short =~ "__m_000309"
    assert voiced =~ "__m_003099"
    refute String.downcase(short) == String.downcase(voiced)
  end

  test "a literal case or mark marker does not share a file" do
    docs = Snapshot.path("http://ex.com/Docs")
    literal_case = Snapshot.path("http://ex.com/__u_docs")
    assert literal_case == "ex.com/__u%5fdocs/__index.html"
    assert literal_case != docs
    refute String.downcase(literal_case) == String.downcase(docs)

    nfd = "http://ex.com/e" <> <<0x0301::utf8>>
    nfd_path = Snapshot.path(nfd)
    literal_mark = Snapshot.path("http://ex.com/e__m_301")
    assert literal_mark == "ex.com/e__m%5f301/__index.html"
    assert literal_mark != nfd_path
    refute String.downcase(literal_mark) == String.downcase(nfd_path)

    root = tmp("snapshot-literal-markers")
    snap("DOCS", "http://ex.com/Docs", root)
    snap("CASE", "http://ex.com/__u_docs", root)
    snap("NFD", nfd, root)
    snap("MARK", "http://ex.com/e__m_301", root)

    assert File.read!(file(root, "http://ex.com/Docs")) == @utf8_bom <> "DOCS"
    assert File.read!(file(root, "http://ex.com/__u_docs")) == @utf8_bom <> "CASE"
    assert File.read!(file(root, nfd)) == @utf8_bom <> "NFD"
    assert File.read!(file(root, "http://ex.com/e__m_301")) == @utf8_bom <> "MARK"
  end

  test "a decomposed hiragana letter does not share a file with the composed letter" do
    composed = "http://ex.com/" <> <<0x304C::utf8>>
    decomposed = "http://ex.com/" <> <<0x304B::utf8>> <> <<0x3099::utf8>>
    composed_path = Snapshot.path(composed)
    decomposed_path = Snapshot.path(decomposed)

    assert decomposed_path =~ "__m_003099"
    refute decomposed_path =~ <<0x3099::utf8>>
    assert composed_path != decomposed_path
    refute String.downcase(composed_path) == String.downcase(decomposed_path)

    root = tmp("snapshot-hiragana")
    snap("COMPOSED", composed, root)
    snap("DECOMPOSED", decomposed, root)
    assert File.read!(file(root, composed)) == @utf8_bom <> "COMPOSED"
    assert File.read!(file(root, decomposed)) == @utf8_bom <> "DECOMPOSED"
  end

  test "İ does not share a file with I plus a combining dot" do
    dotted = "http://ex.com/" <> <<0x0130::utf8>>
    split = "http://ex.com/" <> <<0x0049::utf8>> <> <<0x0307::utf8>>
    dotted_path = Snapshot.path(dotted)
    split_path = Snapshot.path(split)

    assert dotted_path == "ex.com/__u_000130/__index.html"
    assert split_path =~ "__u_i"
    assert split_path =~ "__m_000307"
    refute String.downcase(dotted_path) == String.downcase(split_path)

    root = tmp("snapshot-dotted-i")
    snap("DOTTED", dotted, root)
    snap("SPLIT", split, root)
    assert File.read!(file(root, dotted)) == @utf8_bom <> "DOTTED"
    assert File.read!(file(root, split)) == @utf8_bom <> "SPLIT"
  end

  test "a decomposed hangul syllable does not share a file with the composed letter" do
    composed = "http://ex.com/" <> <<0xAC00::utf8>>
    decomposed = "http://ex.com/" <> <<0x1100::utf8>> <> <<0x1161::utf8>>
    composed_path = Snapshot.path(composed)
    decomposed_path = Snapshot.path(decomposed)
    literal = Snapshot.path("http://ex.com/__j_001100")

    assert composed_path == "ex.com/" <> <<0xAC00::utf8>> <> "/__index.html"
    assert decomposed_path == "ex.com/__j_001100__j_001161/__index.html"
    assert literal == "ex.com/__j%5f001100/__index.html"
    refute String.downcase(composed_path) == String.downcase(decomposed_path)
    refute String.downcase(literal) == String.downcase(decomposed_path)

    root = tmp("snapshot-hangul")
    snap("COMPOSED", composed, root)
    snap("JAMO", decomposed, root)
    snap("LITERAL", "http://ex.com/__j_001100", root)
    assert File.read!(file(root, composed)) == @utf8_bom <> "COMPOSED"
    assert File.read!(file(root, decomposed)) == @utf8_bom <> "JAMO"
    assert File.read!(file(root, "http://ex.com/__j_001100")) == @utf8_bom <> "LITERAL"
  end

  test "letters that share a lowercase form do not share a file" do
    kay = "http://ex.com/K"
    kelvin = "http://ex.com/" <> <<0x212A::utf8>>

    assert Snapshot.path(kay) == "ex.com/__u_k/__index.html"
    assert Snapshot.path(kelvin) == "ex.com/__u_00212a/__index.html"

    pairs = [
      {0x00C5, "0000c5", 0x212B, "00212b"},
      {0x01C4, "0001c4", 0x01C5, "0001c5"},
      {0x01C7, "0001c7", 0x01C8, "0001c8"},
      {0x01CA, "0001ca", 0x01CB, "0001cb"},
      {0x01F1, "0001f1", 0x01F2, "0001f2"},
      {0x0398, "000398", 0x03F4, "0003f4"},
      {0x03A9, "0003a9", 0x2126, "002126"}
    ]

    for {left, left_hex, right, right_hex} <- pairs do
      assert Snapshot.path("http://ex.com/" <> <<left::utf8>>) ==
               "ex.com/__u_#{left_hex}/__index.html"

      assert Snapshot.path("http://ex.com/" <> <<right::utf8>>) ==
               "ex.com/__u_#{right_hex}/__index.html"
    end

    root = tmp("snapshot-case-fold")
    snap("K", kay, root)
    snap("KELVIN", kelvin, root)
    assert File.read!(file(root, kay)) == @utf8_bom <> "K"
    assert File.read!(file(root, kelvin)) == @utf8_bom <> "KELVIN"
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

    for {letter, marker, other} <- pairs do
      url = "http://ex.com/" <> letter
      other_url = "http://ex.com/" <> other

      assert Snapshot.path(url) == "ex.com/#{marker}/__index.html"
      refute Snapshot.path(url) == Snapshot.path(other_url)

      snap("LETTER", url, root)
      snap("OTHER", other_url, root)
      assert File.read!(file(root, url)) == @utf8_bom <> "LETTER"
      assert File.read!(file(root, other_url)) == @utf8_bom <> "OTHER"
    end
  end

  test "a literal query marker does not share a file" do
    literal = "http://ex.com/app__q_v=1.js"
    query = "http://ex.com/app.js?v=1"
    literal_path = Snapshot.path(literal)
    query_path = Snapshot.path(query)

    assert literal_path == "ex.com/app__q%5fv=1.js"
    assert query_path == "ex.com/app__q_v=1.js"
    refute literal_path =~ "__u_"
    refute String.downcase(literal_path) == String.downcase(query_path)

    root = tmp("snapshot-query-marker")
    snap("LITERAL", literal, root)
    snap("QUERY", query, root)
    assert File.read!(file(root, literal)) == @utf8_bom <> "LITERAL"
    assert File.read!(file(root, query)) == @utf8_bom <> "QUERY"
  end

  test "a byte that is not utf-8 does not share a file with the same character" do
    raw = "http://ex.com/caf" <> <<0xE9>>
    utf8 = "http://ex.com/caf" <> <<0x00E9::utf8>>
    raw_path = Snapshot.path(raw)
    utf8_path = Snapshot.path(utf8)

    assert raw_path =~ "%25e9"
    assert raw_path != utf8_path
    refute String.downcase(raw_path) == String.downcase(utf8_path)

    root = tmp("snapshot-latin1")
    snap("RAW", raw, root)
    snap("UTF8", utf8, root)
    assert File.read!(file(root, raw)) == @utf8_bom <> "RAW"
    assert File.read!(file(root, utf8)) == @utf8_bom <> "UTF8"
  end

  test "scheme and userinfo do not add a directory to a relative link" do
    assert Snapshot.relative("https://ex.com/dir/page", "https://ex.com/other") ==
             "../../../ex.com__scheme_https/other/__index.html"

    assert Snapshot.relative("http://a:b@ex.com/dir/page", "http://a:b@ex.com/other") ==
             "../../../ex.com__user_a%253ab/other/__index.html"

    assert Snapshot.relative("http://ex.com/dir/page", "https://ex.com/other") ==
             "../../../ex.com__scheme_https/other/__index.html"
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

    Enum.each(pairs, fn {url, body} -> snap(body, url, root) end)

    Enum.each(pairs, fn {url, body} ->
      assert File.read!(file(root, url)) == @utf8_bom <> body
    end)

    paths = Enum.map(pairs, fn {url, _} -> String.downcase(Snapshot.path(url)) end)
    assert paths == Enum.uniq(paths)

    page = "http://ex.com/page"

    snap(
      Enum.map_join(pairs, "", fn {url, _} -> ~s(<a href="#{url}"></a>) end),
      page,
      root
    )

    saved = File.read!(file(root, page))

    Enum.each(pairs, fn {url, _body} ->
      assert_saved_expands(saved, page, url, root)
    end)
  end

  defp assert_expands(from_url, link, target_url) do
    href = Linker.offline_link(from_url, link)

    assert Path.expand(link_path(href), Path.dirname(Snapshot.path(from_url))) ==
             Path.expand(Snapshot.path(target_url))
  end

  defp assert_saved_expands(body, from_url, target_url, root) do
    href = Linker.offline_link(from_url, target_url)
    assert body =~ href
    saved = file(root, from_url)

    opened = Path.expand(link_path(href), Path.dirname(saved))
    assert opened == Path.expand(file(root, target_url))
    assert File.read!(opened) == File.read!(file(root, target_url))
  end

  defp file(root, url), do: Path.join(root, Snapshot.path(url))

  defp snap(body, url, root) do
    assert {:ok, _opts} =
             Snapper.snap(body, %{
               url: url,
               referrer_url: url,
               save_to: root,
               html_tag: "a",
               content_type: "text/html",
               depth: 1,
               max_depths: 2
             })
  end
end
