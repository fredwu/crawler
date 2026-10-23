defmodule Crawler.CrawlSnapshotPublishTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store

  test "a retired slower export cannot replace a newer complete archive", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("lifecycle-slow-save")
    page = "#{url}/lifecycle/slow-save"
    root = tmp("lifecycle-slow-save-#{System.unique_integer([:positive])}")
    on_exit(fn -> cleanup_exports([scope], root) end)
    {:ok, hits} = Agent.start_link(fn -> 0 end)

    ReqTestSite.stub(site, "GET", "/lifecycle/slow-save", fn conn ->
      count = Agent.get_and_update(hits, fn count -> {count, count + 1} end)

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.resp(200, if(count == 0, do: "OLD", else: "NEW"))
    end)

    options = [url: page, scope: scope, store: Store, retries: 0, req_options: req_options]
    assert {:ok, old} = stage_copy(options ++ [save_to: Path.join(root, "old")])
    {first, holder, receipt} = hold_finalizer(old)
    assert File.dir?(receipt.stage)
    refute File.exists?(old.save_to)

    generation = Store.drop_scope(scope)
    refute generation == old.generation
    assert {:ok, fresh} = stage_copy(options ++ [save_to: Path.join(root, "new")])
    assert {:ok, :committed} = finalize_copy(fresh)
    export = ready_export(fresh)
    resource = resource_for_url(export, page)
    assert read_resource(export, resource) == "NEW"
    assert %Store.Page{body: "NEW", processed: true} = Store.find_processed({page, scope})

    send(holder, :release_save)
    assert {:error, _} = Task.await(first, 5_000)

    wait(fn ->
      refute File.exists?(receipt.stage)
      refute Process.alive?(holder)
    end)

    refute File.exists?(old.save_to)
    assert read_resource(export, resource) == "NEW"
    assert ready_export(fresh) == export
    cleanup_exports([scope], root)
  end

  test "concurrent exports of one destination keep one complete archive", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    page = "#{url}/lifecycle/bodies"
    a_scope = unique_scope("lifecycle-body-a")
    b_scope = unique_scope("lifecycle-body-b")
    root = tmp("lifecycle-bodies-#{System.unique_integer([:positive])}")
    destination = Path.join(root, "archive")
    on_exit(fn -> cleanup_exports([a_scope, b_scope], root) end)
    {:ok, hits} = Agent.start_link(fn -> 0 end)

    ReqTestSite.stub(site, "GET", "/lifecycle/bodies", fn conn ->
      count = Agent.get_and_update(hits, fn count -> {count, count + 1} end)

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.resp(200, "BODY-#{count}")
    end)

    options = [
      url: page,
      save_to: destination,
      store: Store,
      req_options: req_options,
      max_body: 1024,
      max_analysis_bytes: 2_097_152,
      max_manifest_bytes: 1_048_576
    ]

    assert {:ok, first} = stage_copy(options ++ [scope: a_scope])
    {task, holder, receipt} = hold_finalizer(first)
    refute File.exists?(destination)
    assert File.dir?(receipt.stage)

    assert {:error, reason} =
             stage_copy(options ++ [scope: b_scope])

    assert reason == {:snapshot, :destination_owned}
    send(holder, :release_save)
    assert {:ok, :committed} = Task.await(task, 5_000)
    export = ready_export(first)
    assert [resource] = export.manifest["resources"]
    assert resource == resource_for_url(export, page)
    assert read_resource(export, resource) == "BODY-0"
    refute File.exists?(receipt.stage)
    assert Enum.sort(File.ls!(destination)) == ["manifest.json", "resources"]
    cleanup_exports([a_scope, b_scope], root)
  end

  test "stopping an export before commit removes private staging", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("lifecycle-stop-save")
    page = "#{url}/lifecycle/stop-save"

    destination =
      Path.join(tmp("lifecycle-stop-save-#{System.unique_integer([:positive])}"), "archive")

    root = Path.dirname(destination)
    on_exit(fn -> cleanup_exports([scope], root) end)

    ReqTestSite.stub(site, "GET", "/lifecycle/stop-save", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.resp(200, "PARTIAL")
    end)

    assert {:ok, opts} =
             stage_copy(
               url: page,
               scope: scope,
               store: Store,
               save_to: destination,
               req_options: req_options
             )

    {task, holder, receipt} = hold_finalizer(opts)
    assert File.dir?(receipt.stage)
    assert File.regular?(Path.join(receipt.stage, "archive/manifest.json"))
    refute File.exists?(destination)
    assert :ok = Crawler.stop(opts)
    send(holder, :release_save)
    assert {:error, _} = Task.await(task, 5_000)

    wait(fn ->
      refute File.exists?(receipt.stage)
      refute Process.alive?(holder)
    end)

    refute File.exists?(destination)
    refute Store.find({page, scope})
    cleanup_exports([scope], root)
  end

  defp cleanup_exports(scopes, root) do
    owned = fn {{scope, _generation}, _record} -> Enum.any?(scopes, &(&1 === scope)) end
    exports = Enum.filter(:sys.get_state(Store).exports, owned)
    Enum.each(scopes, &Store.dispose_scope/1)

    wait(fn ->
      refute Enum.any?(:sys.get_state(Store).exports, owned)
      Enum.each(exports, &assert_filesystem_released/1)
    end)

    File.rm_rf!(root)
  end

  defp assert_filesystem_released({_run, record}) do
    if is_pid(record.filesystem), do: refute(Process.alive?(record.filesystem))

    case record.receipt do
      %{stage: stage} ->
        refute File.exists?(stage)

      _ ->
        :ok
    end
  end

  defp hold_finalizer(opts) do
    parent = self()

    task =
      Task.async(fn ->
        finalize_copy(opts, fn %{filesystem: %{receipt: receipt}} ->
          send(parent, {:staged, self(), receipt})

          receive do
            :release_save -> :ok
          after
            5_000 -> flunk("publication gate was not released")
          end
        end)
      end)

    assert_receive {:staged, holder, receipt}, 2_000
    on_exit(fn -> send(holder, :release_save) end)
    {task, holder, receipt}
  end
end
