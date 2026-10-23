defmodule Crawler.Export.StageTest do
  use ExUnit.Case, async: false

  alias Crawler.Export.Runtime
  alias Crawler.Export.Runtime.Context
  alias Crawler.Export.Stage
  alias Crawler.Export.StagedIO
  alias Crawler.Fetcher
  alias Crawler.Parser
  alias Crawler.Store
  alias Crawler.Store.Execution

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    File.chmod!(root, 0o700)
    Req.Test.set_req_test_to_shared()
    scope = make_ref()

    Req.Test.stub(__MODULE__, fn conn ->
      {type, body} =
        case conn.request_path do
          "/copy" ->
            {"image/png", <<0, 255, 1, 128>>}

          _ ->
            {"text/html",
             ~s|<a href="child#one">one</a><a href="child#one">two</a><img src="missing.png">|}
        end

      conn |> Plug.Conn.put_resp_content_type(type) |> Plug.Conn.resp(200, body)
    end)

    on_exit(fn ->
      Store.dispose_scope(scope)

      assert eventually(fn ->
               not Enum.any?(
                 :sys.get_state(Store).exports,
                 fn {{owner, _generation}, _record} -> owner === scope end
               )
             end)

      Req.Test.set_req_test_to_private()
    end)

    %{root: root, scope: scope}
  end

  test "opaque source and copy metadata use the canonical assignment and real operations", c do
    with_page(c, "/copy", fn runtime, page, export ->
      assert :ok = Stage.source(runtime, page.interpretation, page.credit, export.assignment)
      assert {:ok, fresh} = Store.export_context(runtime.context.opts)
      assert fresh.assignment.dispatch_context.depth == runtime.context.opts.depth + 1
      assert fresh.assignment.dispatch_context.force == false
      assert fresh.assignment.dispatch_context[:execution_lease] == nil
      Store.release_resource(fresh.context_receipt)

      assert {:ok, 1} =
               Stage.stage(runtime, page.interpretation, page.credit, export.assignment, %{})

      row = row(runtime)
      assert row.descriptor.public_id == export.assignment.public_id
      assert row.descriptor.render_mode == :copy
      assert row.bound.operation === row.descriptor.source_operation
      assert row.dirty? == false
      source = session(runtime).staged[row.descriptor.source_operation]
      assert source.path == export.assignment.source_path
      assert source.root_ownership == :borrowed
      assert read(runtime, source) == <<0, 255, 1, 128>>
      assert :done = Store.export_refresh_batch(runtime.context.opts, export.epoch)
      :ok
    end)
  end

  test "authoritative collection stages separate lexical and versioned bound metadata", c do
    with_page(c, "/html", fn runtime, page, export ->
      prepared = %{page.interpretation | occurrences: []}
      assert :ok = Stage.source(runtime, prepared, page.credit, export.assignment)
      before = owned_receipts()
      assert {:ok, 1} = Stage.stage(runtime, prepared, page.credit, export.assignment, %{})
      assert owned_receipts() == before
      row = row(runtime)
      lexical = session(runtime).staged[row.descriptor.lexical_operation]
      bound = session(runtime).staged[row.bound.operation]
      assert lexical.path == export.assignment.lexical_path
      assert bound.path == export.assignment.bound_prefix <> "1.etf"
      assert lexical.analysis_revision === prepared.analysis.revision
      assert lexical.original_budget === prepared.collection.budget
      assert bound.original_budget === prepared.collection.budget
      assert bound.bound_budget.counts === prepared.collection.budget.counts
      assert bound.bound_budget.retained > prepared.collection.budget.retained
      assert bound.unavailable === page.credit.unavailable
      assert bound.bound_budget.limit === prepared.analysis.budget.limit
      assert bound.bound_budget.caps === prepared.analysis.budget.caps
      assert bound.edges_digest === StagedIO.edge_digest(prepared.collection.occurrences)
      assert bound.source_revision === page.source_revision
      refute bound.analysis_revision === page.source_revision
      assert row.bound.css_stamp === prepared.css_revision
      assert row.dirty? == false
      :ok
    end)
  end

  test "refresh replies use available arena capacity and release unused metadata", c do
    with_page(
      c,
      "/copy",
      fn runtime, page, export ->
        opts = runtime.context.opts
        assert :ok = Stage.source(runtime, page.interpretation, page.credit, export.assignment)

        assert {:ok, 1} =
                 Stage.stage(runtime, page.interpretation, page.credit, export.assignment, %{})

        resources = fn ->
          state = :sys.get_state(Store).resources
          {state.used, state.pending_grants, MapSet.new(Map.keys(state.receipts))}
        end

        before = resources.()
        assert :done = Store.export_refresh_batch(opts, export.epoch)
        assert resources.() == before

        assert {:error, :stale_export} = Store.export_refresh_batch(opts, make_ref())
        assert resources.() == before
        :ok
      end,
      %{max_manifest_bytes: 33_554_432}
    )
  end

  test "a funded command fits one measurement workspace under retained arena pressure", c do
    with_page(c, "/copy", fn runtime, page, export ->
      opts = runtime.context.opts
      assert :ok = Stage.source(runtime, page.interpretation, page.credit, export.assignment)

      assert {:ok, 1} =
               Stage.stage(runtime, page.interpretation, page.credit, export.assignment, %{})

      assert {:ok, retained, capacity} =
               Store.reserve_resource_up_to(opts, :scratch, opts.max_retained_bytes)

      try do
        assert capacity > 196_608
        assert :ok = Store.commit_resource(retained, capacity - 196_608)
        before = owned_receipts()
        assert :ok = Store.arm_export(opts, export.epoch)
        assert owned_receipts() == before
      after
        Store.release_resource(retained)
      end

      :ok
    end)
  end

  for privacy <- [:candidate, :private] do
    test "UTF16 #{privacy} decoded source retains its canonical physical witness", c do
      text = "<root><title>café</title></root>"
      wire = <<255, 254>> <> :unicode.characters_to_binary(text, :utf8, {:utf16, :little})

      req_options =
        if unquote(privacy) == :private do
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

          [plug: {Req.Test, __MODULE__}, retry: false]
        end

      with_page(
        c,
        "/utf16",
        fn runtime, page, export ->
          assert page.body === text
          witness = :sys.get_state(Store).executions[runtime.context.opts.execution_lease]
          assert witness.physical_witness.digest === :crypto.hash(:sha256, wire)
          assert witness.decoded_witness.digest === :crypto.hash(:sha256, text)
          assert :ok = Stage.source(runtime, page.interpretation, page.credit, export.assignment)

          assert {:ok, 1} =
                   Stage.stage(runtime, page.interpretation, page.credit, export.assignment, %{})

          source = session(runtime).staged[row(runtime).descriptor.source_operation]
          assert read(runtime, source) === text
          assert source.source_revision === witness.physical_witness.revision
          assert source.digest === witness.decoded_witness.digest
          :ok
        end,
        %{req_options: req_options}
      )
    end
  end

  test "foreign occurrence bindings fail before lexical metadata is written", c do
    with_page(c, "/html", fn runtime, page, export ->
      assert :ok = Stage.source(runtime, page.interpretation, page.credit, export.assignment)
      before = owned_receipts()

      assert {:error, :invalid_bindings} =
               Stage.stage(runtime, page.interpretation, page.credit, export.assignment, %{
                 make_ref() => make_ref()
               })

      assert owned_receipts() == before
      assert map_size(session(runtime).staged) == 1
      :ok
    end)
  end

  test "function-valued bindings refuse before any producer Retained copy measurement", c do
    observer = self()
    key = make_ref()

    with_page(c, "/html", fn runtime, page, export ->
      assert :ok = Stage.source(runtime, page.interpretation, page.credit, export.assignment)
      [occurrence | _] = page.interpretation.collection.occurrences
      invalid = %{occurrence.id => fn -> send(observer, {key, :invoked}) end}
      before = owned_receipts()
      assert :erlang.trace_pattern({Crawler.Store.Retained, :_, :_}, true, [:local]) > 0
      assert 1 = :erlang.trace(self(), true, [:call, {:tracer, observer}])

      try do
        assert {:error, :invalid_bindings} =
                 Stage.stage(
                   runtime,
                   page.interpretation,
                   page.credit,
                   export.assignment,
                   invalid
                 )
      after
        :erlang.trace(self(), false, [:call])
        :erlang.trace_pattern({Crawler.Store.Retained, :_, :_}, false, [:local])
      end

      delivered = :erlang.trace_delivered(self())

      receive do
        {:trace_delivered, _producer, ^delivered} -> :ok
      end

      assert owned_receipts() == before
      assert map_size(session(runtime).staged) == 1
      send(observer, {key, :producer, self()})
      :ok
    end)

    assert_receive {^key, :producer, producer}
    refute_receive {:trace, ^producer, :call, {Crawler.Store.Retained, _function, _args}}
    refute_receive {^key, :invoked}
  end

  test "source substitution with the real revision fails the first-source witness", c do
    with_page(c, "/copy", fn runtime, page, export ->
      prepared = %{page.interpretation | source: <<2, 3, 4, 5>>}

      assert {:error, :source_witness_mismatch} =
               Stage.source(runtime, prepared, page.credit, export.assignment)

      assert {:ok, nil, receipt} = Store.export_source_info(runtime.context.opts, export.epoch)
      Store.release_resource(receipt)
      assert Process.alive?(runtime.companion)
      :ok
    end)
  end

  test "missing source and changed owner assignment refuse before candidate writes", c do
    with_page(c, "/html", fn runtime, page, export ->
      assert {:error, :missing_target_source} =
               Stage.stage(runtime, page.interpretation, page.credit, export.assignment, %{})

      assert {:error, :stale_assignment} =
               Stage.source(runtime, page.interpretation, page.credit, %{
                 export.assignment
                 | public_id: String.duplicate("a", 24)
               })

      assert session(runtime).staged == %{}
      :ok
    end)
  end

  test "one bounded copy refresh preserves waiting, empty progress and done", c do
    caller = self()
    key = make_ref()

    with_page(c, "/copy", fn runtime, page, export ->
      assert :waiting =
               Stage.refresh(runtime, :waiting, fn _, _, _, _ -> flunk("unexpected callback") end)

      assert :done =
               Stage.refresh(runtime, :done, fn _, _, _, _ -> flunk("unexpected callback") end)

      assert {:ok, 1} =
               Stage.refresh(runtime, {:batch, [], 1}, fn _, _, _, _ ->
                 flunk("unexpected callback")
               end)

      assert :ok = Stage.source(runtime, page.interpretation, page.credit, export.assignment)
      assert {:ok, info, receipt} = Store.export_source_info(runtime.context.opts, export.epoch)

      descriptor = %{
        source_operation: info.response.source_handle,
        source_revision: page.source_revision,
        lexical_operation: nil,
        analysis_revision: nil,
        public_id: export.assignment.public_id,
        render_mode: :copy
      }

      assert {:ok, 1} =
               Store.export_candidate(runtime.context.opts, export.epoch, 0, descriptor, %{})

      Store.release_resource(receipt)

      assert {:ok, {:batch, [], 1}, skipped_receipt} =
               Store.export_refresh_batch(runtime.context.opts, export.epoch, 1)

      Store.release_resource(skipped_receipt)
      assert :waiting = Store.export_refresh_batch(runtime.context.opts, export.epoch, 1)
      assert row(runtime).dirty?
      send(caller, {key, runtime.context.opts.generation, runtime.context.job.id})
      :ok
    end)

    assert_receive {^key, generation, target}

    assert :ok =
             Execution.run_job(
               Map.put(options(c, "/refresh"), :generation, generation),
               fn owned ->
                 assert {:ok, export} = Store.export_context(owned)
                 assert {:ok, filesystem} = Store.export_filesystem(owned, export.epoch)

                 try do
                   Runtime.with_io(context(owned, export, filesystem), fn runtime ->
                     assert {:ok, {:batch, [refresh], 1} = batch, batch_receipt} =
                              Store.export_refresh_batch(owned, export.epoch, 1)

                     assert refresh.target === target

                     try do
                       assert {:ok, 1} =
                                Stage.refresh(runtime, batch, fn _, _, _, _ ->
                                  flunk("copy must not reparse")
                                end)

                       assert export_record(runtime).helper.targets[target].dirty? == false
                     after
                       assert {:ok, true} =
                                Store.release_export_refresh(owned, export.epoch, batch_receipt)

                       Store.release_resource(batch_receipt)
                     end

                     assert :done = Store.export_refresh_batch(owned, export.epoch, 1)
                     :ok
                   end)
                 after
                   Store.release_resource(export.context_receipt)
                 end
               end
             )
  end

  test "emit_bound preserves raw callback results and deduplicated member bindings", c do
    body = ~s|<img src="missing.png" srcset="child.png 1x, child.png 2x">|

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, body)
    end)

    with_page(
      c,
      "/html",
      fn runtime, page, export ->
        assert :ok = Stage.source(runtime, page.interpretation, page.credit, export.assignment)
        assert {:ok, fresh} = Store.export_context(runtime.context.opts)

        assert {:ok, index_receipt} =
                 Store.reserve_resource(runtime.context.opts, :scratch, 65_536)

        try do
          owner = self()
          observed = make_ref()

          handler = fn request, opts ->
            url = elem(request, tuple_size(request) - 1)

            if String.ends_with?(url, "missing.png") do
              {:error, :rejected}
            else
              opts = Map.merge(fresh.assignment.dispatch_context, Map.take(opts, [:html_tag]))
              opts = Map.put(opts, :url, url)
              assert {:ok, prepared} = Fetcher.Requester.prepare(opts)

              assert {:ok, claim, :fetch, admitted} =
                       Store.admit_direct(opts, prepared, runtime.context.opts.crawler_deadline)

              send(owner, {{observed, :claim}, claim})
              {:ok, admitted}
            end
          end

          results =
            Parser.emit_bound(page.interpretation, handler, fn occurrence, raw ->
              send(owner, {observed, occurrence.id, raw})
              :ok
            end)

          refute match?({:error, _}, results)
          bindings = collect_bindings(observed, %{})
          assert map_size(bindings) == 3
          [missing, first, second] = page.interpretation.collection.occurrences
          assert is_reference(bindings[first.id])
          assert bindings[second.id] === bindings[first.id]
          assert bindings[missing.id] == nil

          assert {:ok, 1} =
                   Stage.stage(
                     runtime,
                     page.interpretation,
                     page.credit,
                     export.assignment,
                     bindings
                   )

          assert row(runtime).bound.edges_digest ===
                   StagedIO.edge_digest(
                     Enum.map(
                       page.interpretation.collection.occurrences,
                       &%{&1 | target: bindings[&1.id]}
                     )
                   )

          assert_receive {{^observed, :claim}, claim}
          assert :ok = Store.complete_job(claim, Crawler.Job.Outcome.new(:failed, :fixture))
          refute_receive {{^observed, :claim}, _claim}
        after
          Store.release_resource(index_receipt)
          Store.release_resource(fresh.context_receipt)
        end

        :ok
      end,
      %{assets: ["images"]}
    )
  end

  test "resolved CSS uses the exact owner vector without a second scan", c do
    body =
      ~s|<style>.x{--icon:url(icon.png);background:var(--icon)}</style><img class="x" src="own.png">|

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, body)
    end)

    with_page(
      c,
      "/css",
      fn runtime, page, export ->
        prepared = page.interpretation
        assert [_] = prepared.css_collection.groups
        assert [_] = prepared.css_revision
        assert :ok = Stage.source(runtime, prepared, page.credit, export.assignment)
        assert {:ok, 1} = Stage.stage(runtime, prepared, page.credit, export.assignment, %{})
        assert row(runtime).bound.css_stamp === prepared.css_revision
        [group] = prepared.css_collection.groups

        assert row(runtime).memberships[group.style_group].version.revision ===
                 hd(prepared.css_revision)

        :ok
      end,
      %{assets: ["images", "css"]}
    )
  end

  test "cached interpretation registers the existing validated source for its own target", c do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/javascript")
      |> Plug.Conn.resp(200, "const x = 1;")
    end)

    owner = self()
    key = make_ref()

    with_page(
      c,
      "/cached.js",
      fn runtime, page, export ->
        assert :ok = Stage.source(runtime, page.interpretation, page.credit, export.assignment)

        assert {:ok, 1} =
                 Stage.stage(runtime, page.interpretation, page.credit, export.assignment, %{})

        send(
          owner,
          {key, :source, row(runtime).descriptor.source_operation,
           runtime.context.opts.generation}
        )

        :ok
      end,
      %{javascript_goal: :script, store: Store}
    )

    assert_receive {^key, :source, operation, generation}

    with_page(
      c,
      "/cached.js",
      fn runtime, page, export ->
        assert runtime.context.opts.scheduler_mode == :interpret
        assert {:ok, info, receipt} = Store.export_source_info(runtime.context.opts, export.epoch)
        assert info.response.source_handle === operation
        Store.release_resource(receipt)
        assert :ok = Stage.source(runtime, page.interpretation, page.credit, export.assignment)

        assert {:ok, 1} =
                 Stage.stage(runtime, page.interpretation, page.credit, export.assignment, %{})

        assert row(runtime).descriptor.source_operation === operation
        :ok
      end,
      %{javascript_goal: :module, store: Store, generation: generation}
    )
  end

  test "canonical backing follows the actual response when transport supplies a sub-binary", c do
    parent = :binary.copy(<<7>>, 20_000)
    body = binary_part(parent, 200, 100)
    assert :binary.referenced_byte_size(body) == byte_size(parent)

    with_page(
      c,
      "/subbinary",
      fn runtime, page, export ->
        assert page.body === body
        assert :ok = Stage.source(runtime, page.interpretation, page.credit, export.assignment)

        assert {:ok, 1} =
                 Stage.stage(runtime, page.interpretation, page.credit, export.assignment, %{})

        source = session(runtime).staged[row(runtime).descriptor.source_operation]
        assert source.root_bytes == :binary.referenced_byte_size(page.body)
        assert read(runtime, source) === body
        :ok
      end,
      %{
        req_options: [
          adapter: fn request ->
            {request,
             Req.Response.new(status: 200, headers: [{"content-type", "image/png"}], body: body)}
          end
        ]
      }
    )
  end

  test "missing backing credit refuses source publication and releases producer workspaces", c do
    with_page(c, "/copy", fn runtime, page, export ->
      before = owned_receipts()

      assert {:error, {:limit, :backing_capacity}} =
               Stage.source(
                 runtime,
                 page.interpretation,
                 %{page.credit | backing: []},
                 export.assignment
               )

      assert owned_receipts() == before
      assert {:ok, nil, receipt} = Store.export_source_info(runtime.context.opts, export.epoch)
      Store.release_resource(receipt)
      :ok
    end)
  end

  test "a stale assignment refuses a repeated stage without overwriting acknowledged metadata",
       c do
    with_page(c, "/html", fn runtime, page, export ->
      assert :ok = Stage.source(runtime, page.interpretation, page.credit, export.assignment)

      assert {:ok, 1} =
               Stage.stage(runtime, page.interpretation, page.credit, export.assignment, %{})

      staged = session(runtime).staged

      assert {:error, :stale_assignment} =
               Stage.stage(runtime, page.interpretation, page.credit, export.assignment, %{})

      assert session(runtime).staged === staged
      :ok
    end)
  end

  test "a fresh owner assignment reuses exact acknowledged lexical and bound operations", c do
    with_page(c, "/html", fn runtime, page, export ->
      assert :ok = Stage.source(runtime, page.interpretation, page.credit, export.assignment)

      assert {:ok, 1} =
               Stage.stage(runtime, page.interpretation, page.credit, export.assignment, %{})

      staged = session(runtime).staged
      acknowledged = row(runtime).bound
      assert {:ok, fresh} = Store.export_context(runtime.context.opts)

      try do
        assert fresh.assignment.candidate === row(runtime).descriptor
        assert fresh.assignment.bound === acknowledged
        assert :ok = Stage.source(runtime, page.interpretation, page.credit, fresh.assignment)

        assert {:ok, 1} =
                 Stage.stage(runtime, page.interpretation, page.credit, fresh.assignment, %{})

        assert row(runtime).bound === acknowledged
        assert session(runtime).staged === staged
      after
        Store.release_resource(fresh.context_receipt)
      end

      :ok
    end)
  end

  test "four occupied retained roles refuse unfunded binding copies before metadata IO", c do
    with_page(c, "/html", fn runtime, page, export ->
      assert length(page.credit.retained) == 3
      assert :ok = Stage.source(runtime, page.interpretation, page.credit, export.assignment)
      assert {:ok, extra} = Store.reserve_resource(runtime.context.opts, :analysis, 1)

      try do
        credit = %{page.credit | retained: page.credit.retained ++ [extra]}
        before = owned_receipts()

        assert {:error, :unfunded} =
                 Stage.stage(runtime, page.interpretation, credit, export.assignment, %{})

        assert owned_receipts() == before
        assert map_size(session(runtime).staged) == 1
      after
        Store.release_resource(extra)
      end

      :ok
    end)
  end

  test "multiple genuine CSS group stamps stage under the existing analysis limits", c do
    body = css_frames(12)

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, body)
    end)

    with_page(
      c,
      "/frames",
      fn runtime, page, export ->
        assert length(page.interpretation.css_collection.groups) == 12
        assert length(page.interpretation.css_revision) == 12
        stamp_bytes = :erlang.external_size(page.interpretation.css_revision)
        assert stamp_bytes > 256
        assert :ok = Stage.source(runtime, page.interpretation, page.credit, export.assignment)
        result = Stage.stage(runtime, page.interpretation, page.credit, export.assignment, %{})

        assert result == {:ok, 1},
               "Stage.stage returned #{inspect(result)} for #{stamp_bytes}-byte exact CSS vector"

        assert row(runtime).bound.css_stamp === page.interpretation.css_revision
        :ok
      end,
      %{
        assets: ["css", "images"],
        max_css_work: 500,
        max_css_pictures: 100,
        max_manifest_bytes: 4_000_000
      }
    )
  end

  test "more than sixteen CSS memberships use bounded owner queries and one final map", c do
    body = css_frames(17)

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, body)
    end)

    with_page(
      c,
      "/many-frames",
      fn runtime, page, export ->
        assert length(page.interpretation.css_collection.groups) == 17
        assert length(page.interpretation.css_revision) == 17
        assert :ok = Stage.source(runtime, page.interpretation, page.credit, export.assignment)
        before = owned_receipts()

        assert {:ok, 1} =
                 Stage.stage(runtime, page.interpretation, page.credit, export.assignment, %{})

        assert owned_receipts() == before
        assert map_size(row(runtime).memberships) == 17
        assert row(runtime).bound.css_stamp === page.interpretation.css_revision
        :ok
      end,
      %{
        assets: ["css", "images"],
        max_css_work: 500,
        max_css_pictures: 100,
        max_manifest_bytes: 4_000_000
      }
    )
  end

  test "an outdated resolved CSS vector retains its lexical candidate without a bound", c do
    body = ~s|<style>.x{--icon:url(icon.png);background:var(--icon)}</style>|

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, body)
    end)

    with_page(
      c,
      "/css",
      fn runtime, page, export ->
        prepared = page.interpretation
        assert [group] = prepared.css_collection.groups
        assert :ok = Stage.source(runtime, prepared, page.credit, export.assignment)

        css =
          Map.merge(runtime.context.opts, %{mode: :stylesheet, style_group: group.style_group})

        changed = ".x{--icon:url(changed.png);background:var(--icon)}"

        assert {:ok, _} =
                 Crawler.Parser.CssSheets.remember(
                   css,
                   changed,
                   Crawler.Parser.CssParser.Scanner.analyze(changed)
                 )

        assert :superseded = Stage.stage(runtime, prepared, page.credit, export.assignment, %{})
        assert row(runtime).dirty? == true
        assert is_reference(row(runtime).descriptor.lexical_operation)
        assert row(runtime).bound == nil
        assert map_size(session(runtime).staged) == 2
        :ok
      end,
      %{assets: ["css", "images"]}
    )
  end

  test "a no-member CSS fanout returns empty progress before waiting for source metadata", c do
    with_page(c, "/copy", fn runtime, page, export ->
      assert :ok = Stage.source(runtime, page.interpretation, page.credit, export.assignment)
      css = Map.merge(runtime.context.opts, %{mode: :stylesheet, style_group: make_ref()})
      body = "a{background:var(--fallback,url(image.png))}"

      assert {:ok, [_]} =
               Crawler.Parser.CssSheets.remember(
                 css,
                 body,
                 Crawler.Parser.CssParser.Scanner.analyze(body)
               )

      assert {:ok, {:batch, [], 1} = batch, receipt} =
               Store.export_refresh_batch(runtime.context.opts, export.epoch, 1)

      try do
        assert {:ok, 1} =
                 Stage.refresh(runtime, batch, fn _, _, _, _ -> flunk("empty fanout callback") end)
      after
        Store.release_resource(receipt)
      end

      assert {:ok, {:batch, [], 1}, receipt} =
               Store.export_refresh_batch(runtime.context.opts, export.epoch, 1)

      Store.release_resource(receipt)
      assert :waiting = Store.export_refresh_batch(runtime.context.opts, export.epoch, 1)
      :ok
    end)
  end

  test "producer death retires the real companion, filesystem staging and lease grants", c do
    previous = Process.flag(:trap_exit, true)
    caller = self()
    key = make_ref()

    task =
      Task.async(fn ->
        Execution.run_job(options(c, "/html"), fn owned ->
          assert %Crawler.Store.Page{} = page = Fetcher.fetch(Map.put(owned, :save_to, nil))
          assert {:ok, export} = Store.export_context(owned)
          assert {:ok, filesystem} = Store.export_filesystem(owned, export.epoch)

          Runtime.with_io(context(owned, export, filesystem), fn runtime ->
            assert :ok =
                     Stage.source(runtime, page.interpretation, page.credit, export.assignment)

            assert {:ok, 1} =
                     Stage.stage(
                       runtime,
                       page.interpretation,
                       page.credit,
                       export.assignment,
                       %{}
                     )

            send(
              caller,
              {key, self(), runtime.companion, filesystem.filesystem, filesystem.receipt.stage,
               owned.execution_lease}
            )

            receive do
              :finish -> :ok
            end
          end)
        end)
      end)

    assert_receive {^key, producer, companion, filesystem, stage, lease}, 5000
    monitor = Process.monitor(producer)
    Process.exit(producer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^producer, :killed}
    assert catch_exit(Task.await(task)) == {:killed, {Task, :await, [task, 5000]}}
    assert_receive {:EXIT, task_pid, :killed} when task_pid == task.pid
    Process.flag(:trap_exit, previous)
    assert eventually(fn -> not Process.alive?(companion) end)
    Store.dispose_scope(c.scope)
    assert eventually(fn -> not Process.alive?(filesystem) and not File.exists?(stage) end)

    assert eventually(fn ->
             not Enum.any?(:sys.get_state(Store).resources.receipts, fn {_ref, record} ->
               Enum.any?(record.holders, fn {_holder, grant} -> grant.lease === lease end)
             end)
           end)
  end

  test "real sealing resolves successful cycles locally and missing targets safely online", c do
    Req.Test.stub(__MODULE__, fn conn ->
      other = if conn.request_path == "/a", do: "/b", else: "/a"
      body = ~s|<a href="#{other}#loop">cycle</a><a href="/missing#safe">missing</a>|
      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, body)
    end)

    caller = self()
    key = make_ref()

    first =
      Task.async(fn -> cycle_target(c, "/a", %{max_manifest_bytes: 4_000_000}, caller, key) end)

    assert_receive {^key, first_producer, a, generation}, 5000

    second =
      Task.async(fn ->
        cycle_target(
          c,
          "/b",
          %{generation: generation, max_manifest_bytes: 4_000_000},
          caller,
          key
        )
      end)

    assert_receive {^key, second_producer, b, ^generation}, 5000
    send(first_producer, {key, b})
    send(second_producer, {key, a})
    assert :ok = Task.await(first)
    assert :ok = Task.await(second)

    opts =
      options(c, "/a")
      |> Map.merge(%{generation: generation, max_manifest_bytes: 4_000_000})
      |> Crawler.Options.assign_defaults()

    assert {:ok, closed} = Store.close_export(opts)

    assert :ok =
             Execution.run_finalizer(Map.merge(opts, closed), fn owned ->
               assert {:ok, export} = Store.export_context(owned)
               assert {:ok, filesystem} = Store.export_filesystem(owned, export.epoch)

               try do
                 prepare_all(owned, export.epoch, closed.close_token, filesystem.receipt)

                 assert {:ok, %{snapshot: snapshot, staged: staged}, receipt} =
                          Store.export_seal(owned, export.epoch, closed.close_token)

                 try do
                   Runtime.with_io(context(owned, export, filesystem), fn runtime ->
                     for {target, child} <- [{a, b}, {b, a}] do
                       plan = staged[snapshot.artifacts[target].analysis_handle]

                       with_funding(
                         owned,
                         plan.bound_budget.limit - plan.unavailable,
                         plan.unavailable,
                         fn funding ->
                           assert {:ok, ack, stats} =
                                    Runtime.render(runtime, snapshot, target, staged, funding)

                           output = read(runtime, ack.plan)

                           assert output =~
                                    Path.basename(snapshot.artifacts[child].path) <> "#loop"

                           assert output =~ "https://stage.test/missing#safe"
                           assert stats.budget.caps === plan.bound_budget.caps

                           assert stats.budget.counts.occurrences ===
                                    plan.bound_budget.counts.occurrences

                           assert :ok =
                                    Store.export_rendered(
                                      owned,
                                      export.epoch,
                                      snapshot.seal_token,
                                      target,
                                      ack.operation
                                    )

                           :ok
                         end
                       )
                     end

                     :ok
                   end)
                 after
                   Store.release_resource(receipt)
                 end
               after
                 Store.release_resource(export.context_receipt)
               end
             end)
  end

  for phase <- [:before_query, :lexical, :bound] do
    test "a later claimed executor refreshes CSS metadata after #{phase} without replacing its lexical checkpoint",
         c do
      phase = unquote(phase)
      body = ~s|<style>.x{--i:url(one.png);background:var(--i)}</style>|

      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, body)
      end)

      caller = self()
      key = make_ref()
      settings = %{assets: ["css", "images"], max_css_work: 500, max_css_pictures: 100}

      assert :ok =
               Execution.run_job(Map.merge(options(c, "/css-refresh"), settings), fn owned ->
                 assert %Crawler.Store.Page{} =
                          page = Fetcher.fetch(Map.put(owned, :save_to, nil))

                 assert [group] = page.interpretation.css_collection.groups
                 assert {:ok, export} = Store.export_context(owned)
                 assert {:ok, filesystem} = Store.export_filesystem(owned, export.epoch)
                 context = context(owned, export, filesystem)

                 change = fn ->
                   changed = ".x{--i:url(two.png);background:var(--i)}"
                   css = Map.merge(owned, %{mode: :stylesheet, style_group: group.style_group})

                   assert {:ok, _} =
                            Crawler.Parser.CssSheets.remember(
                              css,
                              changed,
                              Crawler.Parser.CssParser.Scanner.analyze(changed)
                            )
                 end

                 context = %{
                   context
                   | written: fn operation, ack ->
                       assert :ok = Store.export_written(owned, export.epoch, operation, ack)

                       if (phase == :lexical and ack.plan.path == export.assignment.lexical_path) or
                            (phase == :bound and
                               String.starts_with?(ack.plan.path, export.assignment.bound_prefix)),
                          do: change.()

                       :ok
                     end
                 }

                 try do
                   Runtime.with_io(context, fn runtime ->
                     assert :ok =
                              Stage.source(
                                runtime,
                                page.interpretation,
                                page.credit,
                                export.assignment
                              )

                     if phase == :before_query, do: change.()

                     assert :superseded =
                              Stage.stage(
                                runtime,
                                page.interpretation,
                                page.credit,
                                export.assignment,
                                %{}
                              )

                     assert row(runtime).bound == nil
                     assert row(runtime).version == 1

                     send(
                       caller,
                       {key, owned.generation, owned.target_handle,
                        row(runtime).descriptor.lexical_operation}
                     )

                     :ok
                   end)
                 after
                   Store.release_resource(export.context_receipt)
                 end
               end)

      assert_receive {^key, generation, target, lexical}

      assert :ok =
               Execution.run_job(
                 Map.merge(options(c, "/refresh"), %{generation: generation}),
                 fn owned ->
                   assert {:ok, export} = Store.export_context(owned)
                   assert {:ok, filesystem} = Store.export_filesystem(owned, export.epoch)

                   try do
                     Runtime.with_io(context(owned, export, filesystem), fn runtime ->
                       assert {:ok, {:batch, [refresh], visited} = batch, receipt} =
                                Store.export_refresh_batch(owned, export.epoch)

                       assert refresh.target === target
                       assert refresh.descriptor.lexical_operation === lexical
                       original = refresh.lexical

                       try do
                         before = owned_receipts()

                         assert {:ok, ^visited} =
                                  Stage.refresh(runtime, batch, fn row, replay, credit, consume ->
                                    opts =
                                      row.assignment.dispatch_context
                                      |> Map.merge(replay.analysis.source_options)
                                      |> Map.merge(
                                        Map.take(owned, [
                                          :execution_lease,
                                          :scheduler_claim,
                                          :crawler_deadline
                                        ])
                                      )
                                      |> Map.put(:source_revision, replay.source_revision)

                                    assert {:ok, addition} =
                                             Store.reserve_resource(
                                               owned,
                                               :analysis,
                                               row.lexical.read_capacity
                                             )

                                    try do
                                      analysis = %{replay.analysis | budget: replay.bound.budget}

                                      assert {:ok, groups} =
                                               Crawler.Analysis.css_groups_result(analysis, opts)

                                      before_css = owned_receipts()

                                      assert {:ok, css} =
                                               Crawler.Parser.CssSheets.resolve_groups(
                                                 opts,
                                                 groups.groups
                                               )

                                      css_receipts =
                                        Map.keys(owned_receipts()) -- Map.keys(before_css)

                                      send(self(), {key, :css_receipts, css_receipts})

                                      assert {:ok, prepared} =
                                               Parser.prepare_collection(
                                                 analysis,
                                                 opts,
                                                 css,
                                                 groups
                                               )

                                      assert prepared.analysis.revision ===
                                               row.descriptor.analysis_revision

                                      assert prepared.analysis.allocation ===
                                               replay.analysis.allocation

                                      consume.(
                                        prepared,
                                        %{credit | retained: credit.retained ++ [addition]},
                                        %{}
                                      )
                                    after
                                      Store.release_resource(addition)
                                    end
                                  end)

                         assert_receive {^key, :css_receipts, css_receipts}
                         assert length(css_receipts) == 2
                         resources = :sys.get_state(Store).resources.receipts

                         assert Enum.sort(Enum.map(css_receipts, &resources[&1].kind)) ==
                                  [:css_facts, :scratch]

                         refute Enum.any?(resources, fn {_ref, record} ->
                                  record.kind == :css_snapshot and
                                    Map.has_key?(record.holders, self())
                                end)

                         assert Map.drop(owned_receipts(), css_receipts) == before
                         send(caller, {key, :producer, self(), owned.execution_lease})
                         updated = export_record(runtime).helper.targets[target]
                         assert updated.dirty? == false
                         assert updated.version == if(phase == :bound, do: 2, else: 1)
                         assert updated.descriptor.lexical_operation === lexical
                         assert session(runtime).staged[lexical] === original

                         assert session(runtime).staged[updated.bound.operation].path ==
                                  refresh.assignment.bound_prefix <>
                                    Integer.to_string(updated.version) <> ".etf"

                         :ok
                       after
                         Store.release_resource(receipt)
                       end
                     end)
                   after
                     Store.release_resource(export.context_receipt)
                   end
                 end
               )

      assert_receive {^key, :producer, producer, lease}

      assert eventually(fn ->
               not Enum.any?(:sys.get_state(Store).resources.receipts, fn {_ref, record} ->
                 match?(%{lease: ^lease}, record.holders[producer])
               end)
             end)
    end
  end

  test "rewrite refresh replays the immutable capsule and releases grants after callback failure",
       c do
    caller = self()
    key = make_ref()

    with_page(c, "/html", fn runtime, page, export ->
      assert :ok = Stage.source(runtime, page.interpretation, page.credit, export.assignment)

      assert {:ok, 1} =
               Stage.stage(runtime, page.interpretation, page.credit, export.assignment, %{})

      assert :superseded =
               Store.export_discovered(
                 runtime.context.opts,
                 export.epoch,
                 0,
                 %{},
                 row(runtime).bound
               )

      send(caller, {key, runtime.context.opts.generation})
      :ok
    end)

    assert_receive {^key, generation}

    assert :ok =
             Execution.run_job(
               Map.put(options(c, "/refresh"), :generation, generation),
               fn owned ->
                 assert {:ok, export} = Store.export_context(owned)
                 assert {:ok, filesystem} = Store.export_filesystem(owned, export.epoch)

                 try do
                   Runtime.with_io(context(owned, export, filesystem), fn runtime ->
                     assert {:ok, {:batch, [_], 1} = batch, receipt} =
                              Store.export_refresh_batch(owned, export.epoch, 1)

                     try do
                       before = owned_receipts()

                       assert_raise RuntimeError, "refresh callback", fn ->
                         Stage.refresh(runtime, batch, fn row, replay, credit, _consume ->
                           assert replay.source_revision === row.descriptor.source_revision
                           assert replay.analysis.revision === row.descriptor.analysis_revision
                           assert replay.original_budget === row.lexical.original_budget
                           assert replay.bound.budget.counts === row.lexical.bound_budget.counts
                           assert replay.bound.budget.peak >= row.lexical.bound_budget.peak

                           assert replay.analysis.limits ===
                                    Map.new(
                                      Crawler.Limits.analysis(row.assignment.dispatch_context)
                                    )

                           assert {:ok, _} =
                                    Crawler.Analysis.continuation_budget(
                                      replay.analysis,
                                      replay.bound
                                    )

                           assert credit.unavailable === row.lexical.unavailable
                           assert length(credit.retained) == 1
                           assert length(credit.backing) == 1
                           raise "refresh callback"
                         end)
                       end

                       assert owned_receipts() == before
                       :ok
                     after
                       Store.release_resource(receipt)
                     end
                   end)
                 after
                   Store.release_resource(export.context_receipt)
                 end
               end
             )
  end

  defp css_frames(count) do
    Enum.map_join(1..count, fn n ->
      ~s|<iframe srcdoc="<style>.x{--i:url(i#{n}.png);background:var(--i)}</style>"></iframe>|
    end)
  end

  defp cycle_target(c, path, extra, caller, key) do
    with_page(
      c,
      path,
      fn runtime, page, export ->
        send(caller, {key, self(), runtime.context.job.id, runtime.context.opts.generation})

        receive do
          {^key, child} ->
            assert :ok =
                     Stage.source(runtime, page.interpretation, page.credit, export.assignment)

            assert {:ok, receipt} = Store.reserve_resource(runtime.context.opts, :scratch, 65_536)

            try do
              assert {:ok, 1} =
                       Stage.stage(
                         runtime,
                         page.interpretation,
                         page.credit,
                         export.assignment,
                         cycle_bindings(page.interpretation, child)
                       )
            after
              Store.release_resource(receipt)
            end
        end

        :ok
      end,
      extra
    )
  end

  defp cycle_bindings(prepared, child) do
    owner = self()
    observed = make_ref()

    handler = fn request, _opts ->
      if elem(request, tuple_size(request) - 1) =~ "/missing",
        do: {:error, :rejected},
        else: {:ok, %{target_handle: child}}
    end

    results =
      Parser.emit_bound(prepared, handler, fn occurrence, raw ->
        send(owner, {observed, occurrence.id, raw})
        :ok
      end)

    refute match?({:error, _}, results)
    collect_bindings(observed, %{})
  end

  defp prepare_all(opts, epoch, token, recovery, cursor \\ nil) do
    case Store.export_prepare_next(opts, epoch, token, cursor, 1) do
      {:ok, {:batch, rows, next}, receipt} ->
        try do
          for row <- rows do
            plan = row.plans.bound

            with_funding(
              opts,
              plan.bound_budget.limit - plan.unavailable,
              plan.unavailable,
              fn funding ->
                assert {:ok, payload} = StagedIO.replay(plan, recovery, funding)

                assert :ok =
                         Store.export_prepared(
                           opts,
                           epoch,
                           token,
                           row.target,
                           row.bound.operation,
                           StagedIO.compact_edges(payload.bound.occurrences)
                         )

                :ok
              end
            )
          end
        after
          Store.release_resource(receipt)
        end

        prepare_all(opts, epoch, token, recovery, next)

      :done ->
        :ok
    end
  end

  defp with_funding(opts, bytes, unavailable, consume) do
    assert {:ok, receipt} = Store.reserve_resource(opts, :snapshot, bytes)

    try do
      assert {:ok, funding} =
               Store.resource_funding(
                 opts,
                 %{retained: [], backing: [], overlap: receipt, unavailable: unavailable}
               )

      consume.(funding)
    after
      Store.release_resource(receipt)
    end
  end

  defp collect_bindings(key, bindings) do
    receive do
      {^key, id, {:ok, %{target_handle: target}}} ->
        collect_bindings(key, Map.put(bindings, id, target))

      {^key, id, _raw} ->
        collect_bindings(key, Map.put(bindings, id, nil))
    after
      0 -> bindings
    end
  end

  defp with_page(c, path, consume, extra \\ %{}) do
    assert :ok =
             Execution.run_job(Map.merge(options(c, path), extra), fn owned ->
               assert %Crawler.Store.Page{} = page = Fetcher.fetch(Map.put(owned, :save_to, nil))
               assert {:ok, export} = Store.export_context(owned)
               assert {:ok, filesystem} = Store.export_filesystem(owned, export.epoch)

               try do
                 Runtime.with_io(context(owned, export, filesystem), fn runtime ->
                   consume.(runtime, page, export)
                 end)
               after
                 Store.release_resource(export.context_receipt)
               end
             end)
  end

  defp context(opts, export, filesystem) do
    epoch = export.epoch

    %Context{
      opts: opts,
      job: export.job,
      executor: self(),
      filesystem: filesystem.filesystem,
      recovery_receipt: filesystem.receipt,
      resource_owner: Process.whereis(Store),
      start_io: &Store.start_export_io(opts, epoch, &1),
      render_funding: &Store.export_render_funding(opts, epoch, &1),
      finish_render: &Store.export_finish_render(opts, epoch, &1, &2),
      reserve: &Store.export_reserve(opts, epoch, &1, &2),
      written: &Store.export_written(opts, epoch, &1, &2),
      custody: &Store.export_custody(opts, epoch, &1, &2, &3),
      deliver: &Store.export_deliver(opts, epoch, &1, &2, &3),
      settled: &Store.export_settled(opts, epoch, &1, &2),
      abandon: &Store.export_abandon(opts, epoch, &1, &2)
    }
  end

  defp options(c, path),
    do: %{
      url: "https://stage.test" <> path,
      scope: c.scope,
      save_to: Path.join(c.root, "archive"),
      store: nil,
      respect_robots: false,
      max_body: 1_000_000,
      max_analysis_bytes: 16_000_000,
      max_manifest_bytes: 262_144,
      attempt_timeout: 10_000,
      retries: 0,
      interval: 0,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }

  defp session(runtime), do: export_record(runtime).helper.session
  defp row(runtime), do: export_record(runtime).helper.targets[runtime.context.job.id]

  defp export_record(runtime),
    do:
      :sys.get_state(Store).exports[
        {runtime.context.opts.scope, runtime.context.opts.generation}
      ]

  defp read(runtime, plan),
    do:
      File.read!(
        Path.join([
          runtime.context.recovery_receipt.stage,
          Atom.to_string(plan.area),
          plan.path
        ])
      )

  defp owned_receipts() do
    :sys.get_state(Store).resources.receipts
    |> Enum.filter(fn {_ref, record} -> Map.has_key?(record.holders, self()) end)
    |> Map.new(fn {ref, record} ->
      {ref, record.actual || record.capacity}
    end)
  end

  defp eventually(fun, remaining \\ 500)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, remaining) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, remaining - 1)
        )
  end
end
