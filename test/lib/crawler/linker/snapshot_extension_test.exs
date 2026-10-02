defmodule Crawler.Linker.SnapshotExtensionTest do
  use ExUnit.Case, async: true

  import Crawler.SnapshotHelpers
  import Crawler.TestHelpers

  alias Crawler.Linker.Snapshot
  alias Crawler.Snapper

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  test "case-sensitive file identities keep recognizable lowercase extensions" do
    for {extensions, expected} <- [
          {~w(CSS CsS css), ".css"},
          {~w(JS Js js), ".js"},
          {~w(HTML Html html), ".html"}
        ] do
      paths =
        for extension <- extensions, query <- ["", "?", "?v=1", "?v=1&x=2"] do
          path = Snapshot.path("http://ex.com/app.#{extension}#{query}")
          assert Path.extname(path) == expected
          path
        end

      assert length(Enum.uniq(paths)) == length(paths)
      assert length(Enum.uniq(Enum.map(paths, &String.downcase/1))) == length(paths)
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

    paths = Enum.map(urls, &Snapshot.path/1)
    assert hd(paths) == "ex.com/app.__u_c__u_s__u_s__ext_.css"
    assert length(Enum.uniq(Enum.map(paths, &String.downcase/1))) == length(paths)
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

    for {url, body, type} <- targets do
      snap(body, url, root, type)
    end

    html = Enum.map_join(targets, "", fn {url, _body, _type} -> ~s(<a href="#{url}"></a>) end)
    snap(html, page, root, "text/html")
    static = Plug.Static.init(at: "/", from: root)

    for {url, body, type} <- targets do
      assert_link_opens(root, page, url)

      response =
        :get
        |> Plug.Test.conn("/" <> Snapshot.url_path(url))
        |> Plug.Static.call(static)

      assert response.status == 200
      expected = if type == "text/html", do: @utf8_bom <> body, else: body
      assert response.resp_body == expected
      assert Plug.Conn.get_resp_header(response, "content-type") == [type]
    end
  end

  defp snap(body, url, root, type) do
    assert {:ok, _opts} =
             Snapper.snap(body, %{
               url: url,
               referrer_url: url,
               save_to: root,
               html_tag: "a",
               content_type: type,
               assets: ["css", "js"],
               depth: 1,
               max_depths: 2
             })
  end
end
