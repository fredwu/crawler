defmodule Crawler.Linker.SnapshotDownloadTest do
  use ExUnit.Case, async: true

  import Crawler.SnapshotHelpers
  import Crawler.TestHelpers

  alias Crawler.Linker.Snapshot
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

    for {url, _filename, type, body} <- targets do
      assert {:ok, _opts} = Snapper.snap(body, %{url: url, content_type: type, save_to: root})
    end

    html =
      Enum.map_join(targets, "", fn {url, _filename, _type, _body} ->
        ~s(<a href="#{url}">Download</a>)
      end)

    assert {:ok, _opts} =
             Snapper.snap(html, %{
               url: page,
               content_type: "text/html",
               save_to: root,
               depth: 1,
               max_depths: 2,
               html_tag: "a"
             })

    links = root |> saved(page) |> File.read!() |> Floki.parse_document!() |> Floki.find("a")
    assert length(links) == length(targets)
    static = Plug.Static.init(at: "/", from: root)

    for {link, {url, filename, type, body}} <- Enum.zip(links, targets) do
      [href] = Floki.attribute(link, "href")
      opened = Path.expand(link_path(href), Path.dirname(saved(root, page)))
      relative = Path.relative_to(opened, root)

      assert Path.basename(relative) == filename
      assert File.read!(opened) == body
      assert_link_opens(root, page, url)

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
      assert Path.basename(download) == filename
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

    paths = Enum.map(urls, &Snapshot.path/1)
    assert hd(paths) == "ex.com/report.docx"
    assert Enum.all?(paths, &(Path.extname(&1) == ".docx"))
    assert length(Enum.uniq(Enum.map(paths, &String.downcase/1))) == length(paths)

    for url <- urls do
      assert link_path(Snapshot.url_path(url)) == Snapshot.path(url)
    end
  end
end
