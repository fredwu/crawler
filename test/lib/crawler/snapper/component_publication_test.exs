defmodule Crawler.Snapper.ComponentPublicationTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store

  test "normal publication uses short independent temp names at the 255-byte boundary" do
    filename = String.duplicate("a", 251) <> ".bin"
    page = "http://ex.com/#{filename}"
    parent_root = tmp(unique_scope("snapshot-component-publication"))
    root = Path.join(parent_root, "archive")
    parent = self()
    body = <<0xFF, 0xE9, 0x89>>
    scope = unique_scope("component-boundary")

    on_exit(fn ->
      Store.drop_scope(scope)
      File.rm_rf(parent_root)
    end)

    adapter = fn request ->
      {request,
       Req.Response.new(
         status: 200,
         headers: [{"content-type", "application/octet-stream"}],
         body: body
       )}
    end

    assert {:ok, opts} =
             stage_copy(%{
               url: page,
               scope: scope,
               save_to: root,
               store: Store,
               workers: 1,
               max_body: 1_048_576,
               max_analysis_bytes: 16_777_216,
               max_manifest_bytes: 16_777_216,
               respect_robots: false,
               req_options: [adapter: adapter, retry: false]
             })

    assert {:ok, :committed} =
             finalize_copy(opts, fn frame ->
               [artifact] = Map.values(frame.snapshot.artifacts)
               staged = Path.join([frame.filesystem.receipt.stage, "archive", artifact.path])
               assert File.read!(staged) == body
               refute File.exists?(root)

               send(
                 parent,
                 {:temp_names, [Path.basename(frame.filesystem.receipt.stage)], artifact.path}
               )
             end)

    assert_receive {:temp_names, [temp], artifact_path}, 1_000
    assert String.starts_with?(temp, ".crawler-fs-")
    assert byte_size(temp) < 64
    refute temp =~ filename
    export = ready_export(opts)
    resource = resource_for_url(export, page)
    assert byte_size(filename) == 255
    assert resource["path"] == artifact_path
    assert resource["path"] =~ ~r/\Aresources\/[0-9a-f]{24}\.bin\z/
    assert read_resource(export, resource) == body
    assert Store.find_processed({page, opts[:scope]}).body == body
    assert File.ls!(Path.join(root, "resources")) == [Path.basename(artifact_path)]
    Crawler.stop(opts)
  end

  test "normal publication opens long query and directory identities" do
    parent_root = tmp(unique_scope("snapshot-long-publication"))
    on_exit(fn -> File.rm_rf(parent_root) end)

    for page <- [
          "http://ex.com/app.css?q=#{String.duplicate("A", 50)}",
          "http://ex.com/#{String.duplicate("A", 100)}/app.css"
        ] do
      root = Path.join(parent_root, unique_scope("archive"))
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
                 max_body: 1_048_576,
                 max_analysis_bytes: 16_777_216,
                 max_manifest_bytes: 16_777_216,
                 respect_robots: false,
                 req_options: [adapter: adapter, retry: false]
               )

      export = ready_export(opts)
      resource = resource_for_url(export, page)
      assert resource["content_type"] == "text/css"
      assert String.ends_with?(resource["path"], ".css")
      assert read_resource(export, resource) == body
      assert Store.find_processed({page, opts[:scope]}).body == body
      assert File.ls!(Path.join(root, "resources")) == [Path.basename(resource["path"])]
      Crawler.stop(opts)
    end
  end
end
