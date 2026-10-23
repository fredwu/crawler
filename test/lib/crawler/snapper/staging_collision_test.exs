defmodule Crawler.Snapper.StagingCollisionTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store

  test "a URL named after an active staging file can publish before that file", context do
    parent_root = root()
    first_url = context.url <> "/first.bin"
    first_destination = Path.join(parent_root, "first")
    observer = self()
    ReqTestSite.expect_once(context.site, "GET", "/first.bin", &bytes(&1, "FIRST"))

    first_options =
      options(first_url, first_destination, context.req_options)
      |> Map.put(:max_manifest_bytes, 4_194_304)

    assert {:ok, first} = stage_copy(first_options)

    {driver, driver_ref} =
      spawn_monitor(fn ->
        result =
          finalize_copy(first, fn frame ->
            [artifact] = Map.values(frame.snapshot.artifacts)
            file = Path.join([frame.filesystem.receipt.stage, "archive", artifact.path])
            send(observer, {:staged, self(), file})

            receive do
              :publish -> :ok
            end
          end)

        send(observer, {:first_result, result})
      end)

    on_exit(fn -> Process.exit(driver, :kill) end)
    assert_receive {:staged, executor, temp}, 2_000
    on_exit(fn -> send(executor, :publish) end)
    basename = Path.basename(temp)
    second_url = context.url <> "/" <> basename
    assert File.regular?(temp)
    assert File.read!(temp) == "FIRST"
    ReqTestSite.expect_once(context.site, "GET", "/" <> basename, &bytes(&1, "SECOND"))

    assert {:ok, second} =
             start_crawl(second_url,
               scope: unique_scope("staging-named-page"),
               workers: 1,
               max_body: 1_048_576,
               max_analysis_bytes: 16_777_216,
               max_manifest_bytes: 4_194_304,
               retries: 0,
               store: Store,
               save_to: Path.join(parent_root, "second"),
               req_options: context.req_options
             )

    on_exit(fn -> Crawler.stop(second) end)
    result = Store.await_direct(second.target_handle, Crawler.Deadline.after_ms(5_000))

    assert {:terminal, %Crawler.Job.Outcome{status: :succeeded}, _} = result,
           "second root canonical outcome: #{inspect(result)}"

    export = ready_export(second)
    assert read_resource(export, resource_for_url(export, second_url)) == "SECOND"
    assert Store.find_processed({second_url, second.scope}).body == "SECOND"
    assert File.read!(temp) == "FIRST"
    refute File.exists?(first_destination)
    refute artifact_path(export, resource_for_url(export, second_url)) == temp

    contender_url = context.url <> "/contender.bin"
    ReqTestSite.expect_once(context.site, "GET", "/contender.bin", &bytes(&1, "CONTENDER"))

    contender =
      options(contender_url, first_destination, context.req_options)
      |> Map.put(:max_manifest_bytes, 4_194_304)

    assert {:error, {:snapshot, :destination_owned}} = stage_copy(contender)
    assert File.read!(temp) == "FIRST"
    send(executor, :publish)
    assert_receive {:first_result, {:ok, :committed}}, 2_000
    assert_receive {:DOWN, ^driver_ref, :process, ^driver, :normal}, 2_000
    first_export = ready_export(first)
    assert read_resource(first_export, resource_for_url(first_export, first_url)) == "FIRST"
    assert read_resource(export, resource_for_url(export, second_url)) == "SECOND"

    assert Enum.reject(
             Path.wildcard(Path.join(parent_root, ".crawler-fs-*"), match_dot: true),
             &(Path.basename(&1) == ".crawler-fs-claims")
           ) == []

    Crawler.stop(first)
    Crawler.stop(second)
  end

  test "completed archives never occupy the staging namespace" do
    parent_root = root()
    destination = Path.join(parent_root, "archive")
    scope = unique_scope("completed-staging-name")
    on_exit(fn -> Store.drop_scope(scope) end)

    urls = [
      "http://example.com/.crawler-1.tmp",
      "http://example.com/.crawler-1.tmp/child.bin",
      "http://example.com/.crawler-2.bin",
      "http://example.com/.crawler%252d1.tmp",
      "http://example.com/.crawler-#{String.duplicate("a", 250)}.bin"
    ]

    for {url, index} <- Enum.with_index(urls) do
      body = "ARCHIVE-#{index}"

      current =
        options(
          url,
          destination,
          [
            adapter: fn request ->
              {request,
               Req.Response.new(
                 status: 200,
                 headers: [{"content-type", "application/octet-stream"}],
                 body: body
               )}
            end,
            retry: false
          ],
          scope
        )

      assert {:ok, _} = stage_copy(current)
    end

    file_url = "http://example.com/after.bin"

    assert {:ok, opts} =
             stage_copy(
               options(
                 file_url,
                 destination,
                 [
                   adapter: fn request ->
                     {request,
                      Req.Response.new(
                        status: 200,
                        headers: [{"content-type", "application/octet-stream"}],
                        body: "AFTER"
                      )}
                   end,
                   retry: false
                 ],
                 scope
               )
             )

    assert {:ok, :committed} = finalize_copy(opts)
    export = ready_export(opts)
    assert read_resource(export, resource_for_url(export, file_url)) == "AFTER"

    for {url, index} <- Enum.with_index(urls) do
      resource = resource_for_url(export, url)
      assert read_resource(export, resource) == "ARCHIVE-#{index}"
      refute Enum.any?(String.split(resource["path"], "/"), &String.starts_with?(&1, ".crawler-"))
      assert Enum.all?(String.split(resource["path"], "/"), &(byte_size(&1) <= 255))
    end

    assert Enum.reject(
             Path.wildcard(Path.join(parent_root, ".crawler-fs-*"), match_dot: true),
             &(Path.basename(&1) == ".crawler-fs-claims")
           ) == []

    Crawler.stop(opts)
  end

  defp options(url, destination, req_options, scope \\ unique_scope("staging-owner")) do
    on_exit(fn -> Store.drop_scope(scope) end)

    %{
      url: url,
      scope: scope,
      save_to: destination,
      content_type: "application/octet-stream",
      store: Store,
      workers: 1,
      max_body: 1_048_576,
      max_analysis_bytes: 16_777_216,
      max_manifest_bytes: 16_777_216,
      respect_robots: false,
      retries: 0,
      req_options: req_options
    }
  end

  defp bytes(conn, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
    |> Plug.Conn.resp(200, body)
  end

  defp root do
    path = tmp(unique_scope("staging-collision"))
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
