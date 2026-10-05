defmodule Crawler.Snapper.StagingCollisionTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers, only: [link_path: 1, saved: 2]

  alias Crawler.Linker.Snapshot
  alias Crawler.Snapper
  alias Crawler.Store

  test "a URL named after an active staging file can publish before that file", context do
    root = root()
    observer = self()
    first_url = context.url <> "/first.bin"
    directory = Path.dirname(saved(root, first_url))

    ReqTestSite.expect_once(context.site, "GET", "/first.bin", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.resp(200, "FIRST")
    end)

    before_publish = fn ->
      [temp] = Path.wildcard(Path.join(directory, ".crawler-*.tmp"), match_dot: true)
      send(observer, {:staged, self(), temp})

      receive do
        :publish -> :ok
      end
    end

    assert {:ok, first} =
             start_crawl(first_url,
               scope: unique_scope("active-staging"),
               workers: 1,
               retries: 0,
               store: Store,
               save_to: root,
               before_publish: before_publish,
               req_options: context.req_options
             )

    on_exit(fn -> Crawler.stop(first) end)
    assert_receive {:staged, worker, temp}, 2_000
    on_exit(fn -> send(worker, :publish) end)
    basename = Path.basename(temp)
    second_url = context.url <> "/" <> basename
    assert File.regular?(temp)
    assert File.read!(temp) == "FIRST"

    ReqTestSite.expect_once(context.site, "GET", "/" <> basename, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.resp(200, "SECOND")
    end)

    assert {:ok, second} =
             start_crawl(second_url,
               scope: unique_scope("staging-named-page"),
               workers: 1,
               retries: 0,
               store: Store,
               save_to: root,
               req_options: context.req_options
             )

    on_exit(fn -> Crawler.stop(second) end)
    await_idle(second)
    assert File.read!(saved(root, second_url)) == "SECOND"
    assert Store.find_processed({second_url, second.scope}).body == "SECOND"
    assert File.read!(temp) == "FIRST"
    refute Path.dirname(saved(root, second_url)) == temp

    send(worker, :publish)
    await_idle(first)
    assert File.read!(saved(root, first_url)) == "FIRST"
    assert File.read!(saved(root, second_url)) == "SECOND"
    assert Path.wildcard(Path.join(root, "**/.crawler-*.tmp"), match_dot: true) == []
  end

  test "completed archives never occupy the staging namespace" do
    root = root()
    scope = unique_scope("completed-staging-name")
    on_exit(fn -> Store.drop_scope(scope) end)
    generation = Store.generation(scope)

    urls = [
      "http://example.com/.crawler-1.tmp",
      "http://example.com/.crawler-1.tmp/child.bin",
      "http://example.com/.crawler-2.bin",
      "http://example.com/.crawler%252d1.tmp",
      "http://example.com/.crawler-#{String.duplicate("a", 250)}.bin"
    ]

    paths = Enum.map(urls, &Snapshot.path/1)
    assert length(Enum.uniq(paths)) == length(urls)

    for {url, index} <- Enum.with_index(urls) do
      path = Snapshot.path(url)
      refute Enum.any?(String.split(path, "/"), &String.starts_with?(&1, ".crawler-"))
      assert Enum.all?(String.split(path, "/"), &(byte_size(&1) <= 255))
      assert link_path(Snapshot.url_path(url)) == path

      assert {:ok, _opts} =
               Snapper.snap("ARCHIVE-#{index}", %{
                 url: url,
                 save_to: root,
                 content_type: "application/octet-stream",
                 scope: scope,
                 generation: generation
               })
    end

    file_url = "http://example.com/after.bin"

    assert {:ok, _opts} =
             Snapper.snap("AFTER", %{
               url: file_url,
               save_to: root,
               content_type: "application/octet-stream",
               scope: scope,
               generation: generation
             })

    assert File.read!(saved(root, file_url)) == "AFTER"

    for {url, index} <- Enum.with_index(urls) do
      assert File.read!(saved(root, url)) == "ARCHIVE-#{index}"
    end

    assert Path.wildcard(Path.join(root, "**/.crawler-*.tmp"), match_dot: true) == []
  end

  defp root do
    path = tmp(unique_scope("staging-collision"))
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
