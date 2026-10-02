defmodule Crawler.Linker.SnapshotComponentTest do
  use ExUnit.Case, async: true

  import Crawler.SnapshotHelpers
  import Crawler.TestHelpers

  alias Crawler.Linker.Snapshot
  alias Crawler.Snapper

  test "filesystem component boundaries keep usable MIME suffixes" do
    for size <- [254, 255, 256] do
      filename = String.duplicate("a", size - 4) <> ".bin"
      path = Snapshot.path("http://ex.com/#{filename}")

      assert_components_fit(path)
      assert Path.extname(path) == ".bin"

      if size <= 255 do
        assert Path.basename(path) == filename
      else
        assert String.starts_with?(Path.basename(path), "__sha256_")
      end
    end
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

    paths = Enum.map(urls, &Snapshot.path/1)
    Enum.each(paths, &assert_components_fit/1)
    assert length(Enum.uniq(Enum.map(paths, &String.downcase/1))) == length(paths)

    [one, two] = Enum.map(Enum.slice(urls, 4, 2), &Snapshot.path/1)
    assert Path.dirname(one) == Path.dirname(two)

    for url <- urls do
      assert link_path(Snapshot.url_path(url)) == Snapshot.path(url)
    end
  end

  test "literal digest names cannot collide with bounded file or directory identities" do
    directory_url = "http://ex.com/#{String.duplicate("A", 100)}"
    directory_path = Snapshot.path(directory_url)
    digest_directory = directory_path |> Path.dirname() |> Path.basename()
    literal_directory_url = "http://ex.com/#{digest_directory}"

    file_url = "http://ex.com/#{String.duplicate("A", 100)}.CSS"
    file_path = Snapshot.path(file_url)
    literal_file_url = "http://ex.com/#{Path.basename(file_path)}"

    assert digest_directory =~ "__sha256_"
    assert Path.extname(file_path) == ".css"
    refute Snapshot.path(literal_directory_url) == directory_path
    refute Snapshot.path(literal_file_url) == file_path

    root = tmp("snapshot-digest-names")
    urls = [directory_url, literal_directory_url, file_url, literal_file_url]

    for {url, index} <- Enum.with_index(urls) do
      body = "BODY-#{index}"

      assert {:ok, _opts} =
               Snapper.snap(body, %{url: url, save_to: root, content_type: "text/plain"})
    end

    for {url, index} <- Enum.with_index(urls) do
      body = "BODY-#{index}"
      assert File.read!(saved(root, url)) == body
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

    for {url, type, body} <- targets do
      assert {:ok, _opts} = Snapper.snap(body, %{url: url, save_to: root, content_type: type})
    end

    html = Enum.map_join(targets, "", fn {url, _type, _body} -> ~s(<a href="#{url}">open</a>) end)

    assert {:ok, _opts} =
             Snapper.snap(html, %{
               url: page,
               save_to: root,
               content_type: "text/html",
               depth: 1,
               max_depths: 2,
               html_tag: "a"
             })

    static = Plug.Static.init(at: "/", from: root)

    for {url, type, body} <- targets do
      assert_link_opens(root, page, url)
      response = :get |> Plug.Test.conn("/" <> Snapshot.url_path(url)) |> Plug.Static.call(static)
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

    for {url, index} <- Enum.with_index(urls) do
      assert {:ok, _opts} =
               Snapper.snap("BODY-#{index}", %{
                 url: url,
                 save_to: root,
                 content_type: "text/plain"
               })
    end

    html = Enum.map_join(urls, "", &~s(<a href="#{&1}">open</a>))

    assert {:ok, _opts} =
             Snapper.snap(html, %{
               url: page,
               save_to: root,
               content_type: "text/html",
               depth: 1,
               max_depths: 2,
               html_tag: "a"
             })

    for {url, index} <- Enum.with_index(urls) do
      assert_components_fit(Snapshot.path(url))
      assert File.read!(saved(root, url)) == "BODY-#{index}"
      assert_link_opens(root, page, url)
    end

    assert Snapshot.path("http://ex.com/app.js/") == Snapshot.path("http://ex.com/app.js")
    paths = Enum.map(urls, &Snapshot.path/1)
    assert length(Enum.uniq(Enum.map(paths, &String.downcase/1))) == length(paths)
  end

  defp assert_components_fit(path) do
    assert Enum.all?(String.split(path, "/"), &(byte_size(&1) <= 255))
  end
end
