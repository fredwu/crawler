defmodule Crawler.Snapper.ComponentPublicationTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers

  alias Crawler.Store

  test "normal publication uses short independent temp names at the 255-byte boundary" do
    filename = String.duplicate("a", 251) <> ".bin"
    page = "http://ex.com/#{filename}"
    root = tmp("snapshot-component-publication")
    parent = self()
    body = <<0xFF, 0xE9, 0x89>>

    adapter = fn request ->
      {request,
       Req.Response.new(
         status: 200,
         headers: [{"content-type", "application/octet-stream"}],
         body: body
       )}
    end

    before_publish = fn ->
      names =
        saved(root, page)
        |> Path.dirname()
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".tmp"))

      send(parent, {:temp_names, names})
    end

    assert {:ok, opts} =
             start_crawl(page,
               scope: unique_scope("component-boundary"),
               save_to: root,
               store: Store,
               workers: 1,
               before_publish: before_publish,
               respect_robots: false,
               req_options: [adapter: adapter, retry: false]
             )

    assert_receive {:temp_names, [temp]}, 1_000
    assert String.starts_with?(temp, ".crawler-")
    assert byte_size(temp) < 64
    refute temp =~ filename
    await_idle(opts)

    assert byte_size(Path.basename(saved(root, page))) == 255
    assert File.read!(saved(root, page)) == body
    assert Store.find_processed({page, opts[:scope]}).body == body
    assert File.ls!(Path.dirname(saved(root, page))) == [filename]
  end

  test "normal publication opens long query and directory identities" do
    root = tmp("snapshot-long-publication")

    for page <- [
          "http://ex.com/app.css?q=#{String.duplicate("A", 50)}",
          "http://ex.com/#{String.duplicate("A", 100)}/app.css"
        ] do
      body = ".café { color: green }"

      adapter = fn request ->
        {request,
         Req.Response.new(
           status: 200,
           headers: [{"content-type", "text/css; charset=utf-8"}],
           body: body
         )}
      end

      assert {:ok, opts} =
               start_crawl(page,
                 scope: unique_scope("long-publication"),
                 save_to: root,
                 store: Store,
                 workers: 1,
                 respect_robots: false,
                 req_options: [adapter: adapter, retry: false]
               )

      await_idle(opts)
      assert File.read!(saved(root, page)) == body
      assert Store.find_processed({page, opts[:scope]}).body == body
      assert File.ls!(Path.dirname(saved(root, page))) == [Path.basename(saved(root, page))]
    end
  end
end
