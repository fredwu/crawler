defmodule Crawler.Phase2.ExportCandidateTest do
  use ExUnit.Case, async: false

  alias Crawler.Export.Runtime
  alias Crawler.Export.Runtime.Context
  alias Crawler.Export.StagedIO
  alias Crawler.Fetcher
  alias Crawler.Store
  alias Crawler.Store.Execution
  alias Crawler.Store.Retained

  setup do
    Req.Test.set_req_test_to_shared()
    {tmp, 0} = System.cmd("pwd", ["-P"], cd: System.tmp_dir!())

    root =
      Path.join(
        String.trim(tmp),
        "crawler-candidate-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    scope = make_ref()

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.resp(200, "png bytes")
    end)

    on_exit(fn ->
      Store.dispose_scope(scope)

      assert eventually(fn ->
               not Enum.any?(:sys.get_state(Store).exports, fn {{owner, _}, _} ->
                 owner === scope
               end)
             end)

      File.rm_rf!(root)
      Req.Test.set_req_test_to_private()
    end)

    %{scope: scope, root: root}
  end

  test "source registration binds the exact fetched revision and charges compact candidate messages",
       c do
    caller = self()
    key = make_ref()

    assert :ok =
             Execution.run_job(options(c), fn owned ->
               assert {:ok, export} = Store.export_context(owned)
               assert export.job.id === owned.target_handle
               assert export.job.opts == %{}
               assert export.job.prepared_request == nil
               assert Crawler.Export.Paths.public_id?(export.assignment.public_id)
               assert export.assignment.dispatch_context == nil
               assert export.assignment.candidate == nil
               assert export.assignment.bound == nil
               assert {:ok, copied} = Retained.copy_bytes(export, owned.max_retained_bytes)

               assert :sys.get_state(Store).resources.receipts[export.context_receipt].actual >=
                        copied

               assert {:ok, nil, empty_receipt} = Store.export_source_info(owned, export.epoch)
               Store.release_resource(empty_receipt)
               assert {:ok, response} = Fetcher.control_request(owned)
               revision = Req.Response.get_private(response, :crawler_source_revision)
               body_receipt = Req.Response.get_private(response, :crawler_response_receipt)

               assert :sys.get_state(Store).executions[owned.execution_lease].source_revision ===
                        revision

               assert {:ok, filesystem} = Store.export_filesystem(owned, export.epoch)
               assert {:ok, overlap} = Store.reserve_resource(owned, :snapshot, 65_536)
               credit = %{retained: [], backing: [body_receipt], overlap: overlap, unavailable: 0}
               assert {:ok, funding} = Store.resource_funding(owned, credit)

               Runtime.with_io(context(export, filesystem, owned), fn runtime ->
                 assert {:ok, ack} =
                          Runtime.stage_source(
                            runtime,
                            "sources/root",
                            response.body,
                            revision,
                            :borrowed,
                            funding
                          )

                 operation = ack.operation
                 assert is_reference(operation)

                 for {type, url} <- [
                       {"text/html", owned.url},
                       {"image/png", "https://candidate.test/foreign.png"}
                     ] do
                   assert {:error, :source_witness_mismatch} =
                            Store.export_source(owned, export.epoch, operation, type, url)
                 end

                 assert {:ok, wrong} =
                          Runtime.stage_source(
                            runtime,
                            "sources/wrong-bytes",
                            "bad bytes",
                            revision,
                            :borrowed,
                            funding
                          )

                 assert {:error, :source_witness_mismatch} =
                          Store.export_source(
                            owned,
                            export.epoch,
                            wrong.operation,
                            "image/png",
                            owned.url
                          )

                 assert :ok =
                          Store.export_source(
                            owned,
                            export.epoch,
                            operation,
                            "image/png",
                            owned.url
                          )

                 assert {:ok, info, receipt} = Store.export_source_info(owned, export.epoch)
                 assert info.response.source_revision === revision
                 assert info.response.source_handle === operation
                 assert info.plan === ack.plan
                 assert {:ok, copy} = Retained.copy_bytes(info, owned.max_retained_bytes)
                 assert :sys.get_state(Store).resources.receipts[receipt].actual >= copy
                 Store.release_resource(receipt)

                 assert :ok =
                          Store.export_source(
                            owned,
                            export.epoch,
                            operation,
                            "image/png",
                            owned.url
                          )

                 assert {:ok, current} = Store.export_context(owned)
                 assert current.assignment.public_id === export.assignment.public_id
                 assert current.assignment.source_path === export.assignment.source_path
                 assert current.assignment.dispatch_context.depth == owned.depth + 1
                 assert current.assignment.dispatch_context.force == false
                 refute Map.has_key?(current.assignment.dispatch_context, :execution_lease)
                 Store.release_resource(current.context_receipt)

                 descriptor = %{
                   source_operation: operation,
                   source_revision: revision,
                   lexical_operation: nil,
                   analysis_revision: nil,
                   public_id: export.assignment.public_id,
                   render_mode: :copy
                 }

                 assert {:ok, 1} = Store.export_candidate(owned, export.epoch, 0, descriptor, %{})
                 assert {:ok, 1} = Store.export_candidate(owned, export.epoch, 1, descriptor, %{})

                 record = :sys.get_state(Store).exports[{owned.scope, owned.generation}]
                 assert record.helper.targets[owned.target_handle].bound == nil

                 assert {:ok, {:batch, [], 1}, skipped_receipt} =
                          Store.export_refresh_batch(owned, export.epoch, 1)

                 Store.release_resource(skipped_receipt)
                 assert :waiting = Store.export_refresh_batch(owned, export.epoch, 1)

                 bound = %{
                   operation: operation,
                   source_revision: revision,
                   analysis_revision: nil,
                   css_stamp: nil,
                   edges_digest: StagedIO.edge_digest([])
                 }

                 assert :ok = Store.export_discovered(owned, export.epoch, 1, %{}, bound)
                 assert :superseded = Store.export_discovered(owned, export.epoch, 0, %{}, bound)
                 assert :ok = Store.export_discovered(owned, export.epoch, 1, %{}, bound)
                 record = :sys.get_state(Store).exports[{owned.scope, owned.generation}]
                 assert record.helper.dirty_count == 0

                 assert {:error, :stale_refresh} =
                          Store.export_refresh_discovered(
                            owned,
                            export.epoch,
                            owned.target_handle,
                            1,
                            %{},
                            bound
                          )

                 assert :superseded = Store.export_discovered(owned, export.epoch, 0, %{}, bound)

                 send(
                   caller,
                   {key, owned.generation, owned.target_handle, descriptor, ack.plan, bound}
                 )

                 assert record.helper.session.manifest.targets[owned.target_handle].representation_id ===
                          owned.representation_id

                 :ok
               end)
             end)

    assert_receive {^key, generation, target, descriptor, source, bound}

    assert :ok =
             Execution.run_job(
               Map.merge(options(c), %{
                 url: "https://candidate.test/refresh",
                 generation: generation
               }),
               fn owned ->
                 assert {:ok, export} = Store.export_context(owned)

                 try do
                   assert {:ok, {:batch, [refresh], 1}, refresh_receipt} =
                            Store.export_refresh_batch(owned, export.epoch, 1)

                   try do
                     assert refresh.target === target
                     assert refresh.version == 1
                     assert refresh.descriptor == descriptor
                     assert refresh.source == source
                     assert refresh.lexical == nil
                     assert refresh.groups == %{}
                     assert refresh.bound_descriptor == bound
                     assert refresh.assignment.version == 1
                     assert refresh.assignment.candidate === descriptor
                     assert refresh.assignment.bound === bound
                     assert {:ok, bytes} = Retained.copy_bytes(refresh, owned.max_manifest_bytes)

                     assert :sys.get_state(Store).resources.receipts[refresh_receipt].actual >=
                              bytes

                     assert {:error, :stale_refresh} =
                              Store.export_refresh_candidate(
                                owned,
                                export.epoch,
                                make_ref(),
                                1,
                                descriptor,
                                %{}
                              )

                     assert {:ok, 1} =
                              Store.export_refresh_candidate(
                                owned,
                                export.epoch,
                                target,
                                1,
                                descriptor,
                                %{}
                              )

                     assert :ok =
                              Store.export_refresh_discovered(
                                owned,
                                export.epoch,
                                target,
                                1,
                                %{},
                                bound
                              )

                     record = :sys.get_state(Store).exports[{owned.scope, owned.generation}]
                     assert record.helper.targets[target].dirty? == false

                     assert :superseded =
                              Store.export_refresh_discovered(
                                owned,
                                export.epoch,
                                target,
                                1,
                                %{},
                                bound
                              )
                   after
                     assert {:ok, true} =
                              Store.release_export_refresh(owned, export.epoch, refresh_receipt)

                     Store.release_resource(refresh_receipt)
                   end

                   assert :done = Store.export_refresh_batch(owned, export.epoch, 1)
                   :ok
                 after
                   Store.release_resource(export.context_receipt)
                 end
               end
             )
  end

  test "a dead refresh consumer releases its batch and preserves later ownership", c do
    {generation, first, first_bound} = copy_candidate(c, "/first.png", nil)
    {^generation, second, second_bound} = copy_candidate(c, "/second.png", generation)
    bounds = %{first => first_bound, second => second_bound}
    caller = self()
    key = make_ref()

    opts =
      Map.merge(options(c), %{url: "https://candidate.test/consumer", generation: generation})

    {consumer, consumer_monitor} =
      spawn_monitor(fn ->
        try do
          Execution.run_job(opts, fn owned ->
            assert {:ok, export} = Store.export_context(owned)

            assert {:ok, {:batch, [completed, pending], 2}, receipt} =
                     Store.export_refresh_batch(owned, export.epoch, 2)

            assert MapSet.new([completed.target, pending.target]) == MapSet.new([first, second])
            consume_copy(owned, export, completed, bounds[completed.target])
            batch = :sys.get_state(Store).executions[owned.execution_lease].export_refresh
            assert batch.selected == %{first => 1, second => 1}
            assert batch.owner === {owned.execution_lease, receipt}
            assert batch.receipt === receipt
            assert batch.epoch === export.epoch
            metadata = :sys.get_state(Store).resources.receipts[batch.metadata]
            assert metadata.capacity == 8192
            assert Map.has_key?(metadata.holders, Process.whereis(Store))

            send(
              caller,
              {key, self(), owned.execution_lease, export.epoch, receipt, batch.metadata,
               completed.target, pending.target}
            )

            receive do
              {^key, :unexpected_resume} -> flunk("consumer must die with its batch held")
            end
          end)
        catch
          :exit, :killed -> :ok
        end
      end)

    on_exit(fn -> Process.exit(consumer, :kill) end)

    assert_receive {^key, executor, lease, epoch, old_receipt, old_metadata, completed, pending},
                   1_000

    executor_monitor = Process.monitor(executor)
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^executor_monitor, :process, ^executor, :killed}, 1_000
    assert_receive {:DOWN, ^consumer_monitor, :process, ^consumer, :normal}, 1_000

    assert eventually(fn ->
             state = :sys.get_state(Store)

             not Map.has_key?(state.executions, lease) and
               not Map.has_key?(state.resources.receipts, old_metadata) and
               not Map.has_key?(state.resources.receipts, old_receipt)
           end)

    helper = :sys.get_state(Store).exports[{c.scope, generation}].helper
    assert helper.targets[completed].dirty? == false
    assert helper.targets[completed].refreshing? == false
    assert helper.targets[pending].dirty?
    assert helper.targets[pending].refreshing? == false
    assert helper.targets[pending].refresh_owner == nil
    assert Map.keys(helper.dirty.members) == [pending]

    assert :ok =
             Execution.run_job(
               Map.put(opts, :url, "https://candidate.test/later-consumer"),
               fn owned ->
                 assert {:ok, export} = Store.export_context(owned)
                 assert export.epoch === epoch

                 try do
                   assert {:ok, {:batch, [refresh], 1}, receipt} =
                            Store.export_refresh_batch(owned, epoch, 1)

                   assert refresh.target === pending
                   assert refresh.version == 1
                   assert receipt !== old_receipt
                   batch = :sys.get_state(Store).executions[owned.execution_lease].export_refresh
                   assert batch.owner === {owned.execution_lease, receipt}
                   assert batch.selected == %{pending => 1}
                   assert batch.metadata !== old_metadata

                   try do
                     assert {:ok, false} = Store.release_export_refresh(owned, epoch, old_receipt)
                     assert {:error, :unknown_grant} = Store.release_resource(old_receipt)
                     state = :sys.get_state(Store)
                     assert state.executions[owned.execution_lease].export_refresh === batch
                     row = state.exports[{c.scope, generation}].helper.targets[pending]
                     assert row.refreshing?
                     assert row.refresh_owner === batch.owner
                     consume_copy(owned, export, refresh, bounds[pending])
                   after
                     assert {:ok, true} = Store.release_export_refresh(owned, epoch, receipt)
                     Store.release_resource(receipt)
                   end

                   state = :sys.get_state(Store)
                   assert state.executions[owned.execution_lease][:export_refresh] == nil
                   refute Map.has_key?(state.resources.receipts, batch.metadata)
                   assert state.exports[{c.scope, generation}].helper.dirty_count == 0
                   assert :done = Store.export_refresh_batch(owned, epoch, 1)
                   :ok
                 after
                   Store.release_resource(export.context_receipt)
                 end
               end
             )
  end

  test "a new canonical interpretation revalidates the existing decoded source operation", c do
    parent = self()
    marker = make_ref()
    text = "<svg><title>café</title></svg>"
    wire = <<255, 254>> <> :unicode.characters_to_binary(text, :utf8, {:utf16, :little})

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, marker)
      conn |> Plug.Conn.put_resp_content_type("image/svg+xml") |> Plug.Conn.resp(200, wire)
    end)

    rows =
      for group <- [:first, :second] do
        opts =
          Map.merge(options(c), %{
            style_group: group,
            store: nil,
            force: false,
            html_tag: "a",
            cookie_navigation: false,
            max_analysis_bytes: 2_000_000
          })

        assert {:ok, row} =
                 Execution.run_job(opts, fn owned ->
                   assert %Crawler.Store.Page{body: ^text} =
                            page = Fetcher.fetch(Map.put(owned, :save_to, nil))

                   assert {:ok, export} = Store.export_context(owned)
                   assert {:ok, info, receipt} = Store.export_source_info(owned, export.epoch)
                   Store.release_resource(receipt)
                   assert {:ok, filesystem} = Store.export_filesystem(owned, export.epoch)
                   assert {:ok, overlap} = Store.reserve_resource(owned, :snapshot, 65_536)

                   credit =
                     Map.put(
                       Map.take(page.credit, [:retained, :backing, :unavailable]),
                       :overlap,
                       overlap
                     )

                   assert {:ok, funding} = Store.resource_funding(owned, credit)

                   try do
                     Runtime.with_io(context(export, filesystem, owned), fn runtime ->
                       operation =
                         if info do
                           assert info.response.source_revision === page.source_revision
                           assert info.plan.digest == :crypto.hash(:sha256, text)
                           info.response.source_handle
                         else
                           assert {:ok, ack} =
                                    Runtime.stage_source(
                                      runtime,
                                      export.assignment.source_path,
                                      text,
                                      page.source_revision,
                                      :borrowed,
                                      funding
                                    )

                           ack.operation
                         end

                       assert :ok =
                                Store.export_source(
                                  owned,
                                  export.epoch,
                                  operation,
                                  page.opts.content_type,
                                  page.opts.url
                                )

                       assert :ok =
                                Store.export_source(
                                  owned,
                                  export.epoch,
                                  operation,
                                  page.opts.content_type,
                                  page.opts.url
                                )

                       assert {:ok, updated} = Store.export_context(owned)
                       refute is_nil(updated.assignment.dispatch_context)
                       assert updated.assignment.dispatch_context.style_group === group
                       Store.release_resource(updated.context_receipt)

                       assert {:error, :source_witness_mismatch} =
                                Store.export_source(
                                  owned,
                                  export.epoch,
                                  operation,
                                  "text/html",
                                  page.opts.url
                                )

                       {:ok,
                        %{
                          target: owned.target_handle,
                          representation: owned.representation_id,
                          operation: operation,
                          revision: page.source_revision,
                          public_id: updated.assignment.public_id
                        }}
                     end)
                   after
                     Store.release_resource(overlap)
                   end
                 end)

        row
      end

    [first, second] = rows
    assert first.target !== second.target
    assert first.public_id !== second.public_id
    assert first.representation === second.representation
    assert first.operation === second.operation
    assert first.revision === second.revision
    assert_receive ^marker
    refute_receive ^marker
  end

  test "an unrelated staged source cannot become the target response", c do
    assert :ok =
             Execution.run_job(options(c), fn owned ->
               assert {:ok, export} = Store.export_context(owned)
               assert {:ok, response} = Fetcher.control_request(owned)
               assert {:ok, filesystem} = Store.export_filesystem(owned, export.epoch)
               assert {:ok, overlap} = Store.reserve_resource(owned, :snapshot, 65_536)

               credit = %{
                 retained: [],
                 backing: [Req.Response.get_private(response, :crawler_response_receipt)],
                 overlap: overlap,
                 unavailable: 0
               }

               assert {:ok, funding} = Store.resource_funding(owned, credit)

               Runtime.with_io(context(export, filesystem, owned), fn runtime ->
                 assert {:ok, ack} =
                          Runtime.stage_source(
                            runtime,
                            "sources/unrelated",
                            response.body,
                            make_ref(),
                            :borrowed,
                            funding
                          )

                 operation = ack.operation
                 assert is_reference(operation)

                 assert {:error, :source_revision_mismatch} =
                          Store.export_source(
                            owned,
                            export.epoch,
                            operation,
                            "image/png",
                            owned.url
                          )

                 assert {:ok, nil, receipt} = Store.export_source_info(owned, export.epoch)
                 Store.release_resource(receipt)
                 assert Process.alive?(Process.whereis(Store))
                 :ok
               end)
             end)
  end

  test "bounded refresh consumes empty CSS fanouts before close", c do
    parent = self()

    assert {:error, :fixture_failure} =
             Execution.run_job(options(c), fn owned ->
               assert {:ok, export} = Store.export_context(owned)

               css =
                 Map.merge(owned, %{
                   mode: :stylesheet,
                   style_group: make_ref(),
                   max_css_work: 100,
                   max_css_pictures: 100
                 })

               body = "a{background:var(--fallback,url(image.png))}"

               assert {:ok, [_]} =
                        Crawler.Parser.CssSheets.remember(
                          css,
                          body,
                          Crawler.Parser.CssParser.Scanner.analyze(body)
                        )

               run = {owned.scope, owned.generation}
               assert :sys.get_state(Store).exports[run].helper.pending_fanouts == 1

               assert {:ok, versions, versions_receipt} =
                        Store.export_group_versions(owned, export.epoch, [css.style_group])

               assert versions[css.style_group] ===
                        :sys.get_state(Store).exports[run].helper.groups[css.style_group].version

               assert {:ok, bytes} = Retained.copy_bytes(versions, owned.max_manifest_bytes)

               assert :sys.get_state(Store).resources.receipts[versions_receipt].actual >= bytes
               Store.release_resource(versions_receipt)

               assert {:error, :unknown_css_group} =
                        Store.export_group_versions(owned, export.epoch, [make_ref()])

               assert {:ok, {:batch, [], 1}, receipt} =
                        Store.export_refresh_batch(owned, export.epoch, 1)

               Store.release_resource(receipt)
               assert :done = Store.export_refresh_batch(owned, export.epoch, 1)
               assert :sys.get_state(Store).exports[run].helper.pending_fanouts == 0
               send(parent, {:refreshed_owner, owned})
               {:error, :fixture_failure}
             end)

    assert_receive {:refreshed_owner, owned}
    opts = Map.drop(owned, [:execution_lease, :scheduler_claim, :crawler_deadline])
    assert {:ok, _closed} = Store.close_export(opts)
  end

  for privacy <- [:candidate, :private] do
    test "UTF16 decoded registration uses its physical witness for #{privacy} responses", c do
      text = "<root><title>café</title></root>"
      wire = <<255, 254>> <> :unicode.characters_to_binary(text, :utf8, {:utf16, :little})
      privacy = unquote(privacy)

      req_options =
        if privacy == :private do
          [
            adapter: fn request ->
              {request,
               Req.Response.new(
                 status: 200,
                 headers: [{"content-type", "application/xml"}],
                 body: wire
               )}
            end
          ]
        else
          Req.Test.stub(__MODULE__, fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/xml")
            |> Plug.Conn.resp(200, wire)
          end)

          [plug: {Req.Test, __MODULE__}]
        end

      assert :ok =
               Execution.run_job(
                 Map.merge(options(c), %{req_options: req_options, max_analysis_bytes: 2_000_000}),
                 fn owned ->
                   assert %Crawler.Store.Page{body: ^text} =
                            page = Fetcher.fetch(Map.put(owned, :save_to, nil))

                   assert {:ok, export} = Store.export_context(owned)
                   execution = :sys.get_state(Store).executions[owned.execution_lease]
                   assert execution.physical_witness.digest == :crypto.hash(:sha256, wire)
                   assert execution.decoded_witness.digest == :crypto.hash(:sha256, text)
                   assert execution.physical_witness.revision === page.source_revision
                   assert execution.decoded_witness.revision === page.source_revision
                   assert execution.decoded_witness.decoder_seed.retained > 0

                   assert {:ok, filesystem} = Store.export_filesystem(owned, export.epoch)
                   assert {:ok, overlap} = Store.reserve_resource(owned, :snapshot, 65_536)
                   credit = Map.take(page.credit, [:retained, :backing, :unavailable])
                   credit = Map.put(credit, :overlap, overlap)
                   assert {:ok, funding} = Store.resource_funding(owned, credit)

                   Runtime.with_io(context(export, filesystem, owned), fn runtime ->
                     assert {:ok, ack} =
                              Runtime.stage_source(
                                runtime,
                                "sources/converted",
                                text,
                                page.source_revision,
                                :borrowed,
                                funding
                              )

                     assert :ok =
                              Store.export_source(
                                owned,
                                export.epoch,
                                ack.operation,
                                "application/xml",
                                owned.url
                              )

                     :ok
                   end)
                 end
               )
    end
  end

  defp copy_candidate(c, path, generation) do
    caller = self()
    key = make_ref()
    opts = Map.put(options(c), :url, "https://candidate.test" <> path)
    opts = if generation, do: Map.put(opts, :generation, generation), else: opts

    assert :ok =
             Execution.run_job(opts, fn owned ->
               assert {:ok, response} = Fetcher.control_request(owned)
               revision = Req.Response.get_private(response, :crawler_source_revision)
               body_receipt = Req.Response.get_private(response, :crawler_response_receipt)
               assert {:ok, export} = Store.export_context(owned)
               assert {:ok, filesystem} = Store.export_filesystem(owned, export.epoch)
               assert {:ok, overlap} = Store.reserve_resource(owned, :snapshot, 65_536)
               credit = %{retained: [], backing: [body_receipt], overlap: overlap, unavailable: 0}
               assert {:ok, funding} = Store.resource_funding(owned, credit)

               try do
                 Runtime.with_io(context(export, filesystem, owned), fn runtime ->
                   assert {:ok, ack} =
                            Runtime.stage_source(
                              runtime,
                              export.assignment.source_path,
                              response.body,
                              revision,
                              :borrowed,
                              funding
                            )

                   assert :ok =
                            Store.export_source(
                              owned,
                              export.epoch,
                              ack.operation,
                              "image/png",
                              owned.url
                            )

                   descriptor = %{
                     source_operation: ack.operation,
                     source_revision: revision,
                     lexical_operation: nil,
                     analysis_revision: nil,
                     public_id: export.assignment.public_id,
                     render_mode: :copy
                   }

                   bound = %{
                     operation: ack.operation,
                     source_revision: revision,
                     analysis_revision: nil,
                     css_stamp: nil,
                     edges_digest: StagedIO.edge_digest([])
                   }

                   assert {:ok, 1} =
                            Store.export_candidate(owned, export.epoch, 0, descriptor, %{})

                   send(caller, {key, owned.generation, owned.target_handle, bound})
                   :ok
                 end)
               after
                 Store.release_resource(export.context_receipt)
               end
             end)

    assert_receive {^key, generation, target, bound}
    {generation, target, bound}
  end

  defp consume_copy(owned, export, refresh, bound) do
    assert {:ok, version} =
             Store.export_refresh_candidate(
               owned,
               export.epoch,
               refresh.target,
               refresh.version,
               refresh.descriptor,
               %{}
             )

    assert :ok =
             Store.export_refresh_discovered(
               owned,
               export.epoch,
               refresh.target,
               version,
               %{},
               bound
             )
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, remaining) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, remaining - 1)
    end
  end

  defp context(export, filesystem, owned) do
    %Context{
      job: export.job,
      opts: owned,
      executor: self(),
      filesystem: filesystem.filesystem,
      recovery_receipt: filesystem.receipt,
      resource_owner: Process.whereis(Store),
      start_io: &Store.start_export_io(owned, export.epoch, &1),
      render_funding: &Store.export_render_funding(owned, export.epoch, &1),
      finish_render: &Store.export_finish_render(owned, export.epoch, &1, &2),
      reserve: &Store.export_reserve(owned, export.epoch, &1, &2),
      written: &Store.export_written(owned, export.epoch, &1, &2),
      custody: &Store.export_custody(owned, export.epoch, &1, &2, &3),
      deliver: &Store.export_deliver(owned, export.epoch, &1, &2, &3),
      settled: &Store.export_settled(owned, export.epoch, &1, &2),
      abandon: &Store.export_abandon(owned, export.epoch, &1, &2)
    }
  end

  defp options(c) do
    %{
      url: "https://candidate.test/root.png",
      scope: c.scope,
      save_to: Path.join(c.root, "archive"),
      max_body: 1024,
      max_analysis_bytes: 1_048_576,
      max_manifest_bytes: 262_144,
      respect_robots: false,
      retries: 0,
      interval: 0,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
  end
end
