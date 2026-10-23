defmodule Crawler.Export.StagedFinalizerTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis
  alias Crawler.Export.Filesystem, as: FS
  alias Crawler.Export.Finalizer
  alias Crawler.Export.Manifest
  alias Crawler.Export.Session
  alias Crawler.Export.StagedIO
  alias Crawler.Job
  alias Crawler.Job.Outcome
  alias Crawler.Store
  alias Crawler.Store.Authority
  alias Crawler.Store.Execution
  alias Crawler.Store.ResourceManager
  alias Crawler.Store.Resources

  @analysis_limits %{
    max_bytes: 1_000_000,
    max_total_bytes: 16_000_000,
    max_regions: 20_000,
    max_depth: 16,
    max_facts: 40_000,
    max_occurrences: 4000,
    max_edits: 4000,
    max_output_bytes: 2_000_000
  }
  @limits %{
    max_targets: 20,
    max_representations: 20,
    max_artifacts: 20,
    max_edges: 4000,
    max_manifest_bytes: 4_000_000,
    max_staged_bytes: 40_000_000,
    max_staged_metadata_bytes: 24_000_000,
    max_file_bytes: 16_000_000,
    max_files: 100
  }

  test "role credits stay disjoint and every imported grant is fenced" do
    with_context(fn c ->
      assert StagedIO.credit_spec(c.funding) == c.credit

      for malformed <- [
            %{c.credit | retained: [c.resource]},
            %{c.credit | backing: c.credit.retained},
            %{c.credit | retained: List.duplicate(hd(c.credit.retained), 5)},
            %{c.credit | backing: [make_ref()]},
            %{c.credit | unavailable: -1}
          ] do
        assert {:error, :unfunded} = StagedIO.funding(c.ledger, malformed, c.lease, self())
      end

      {analysis, original, bound} = analyze("<p>credits</p>", "text/html", fn _ -> nil end)
      {:ok, plan} = plan_metadata("credits.etf", analysis, original, bound, nil, make_ref())

      assert {:ok, overlap_only} =
               StagedIO.funding(
                 c.ledger,
                 %{retained: [], backing: [], overlap: c.resource, unavailable: 0},
                 c.lease,
                 self()
               )

      assert {:error, {:limit, :retained_capacity}} =
               StagedIO.encode(plan, analysis, original, bound, overlap_only)

      assert {:ok, no_backing} =
               StagedIO.funding(c.ledger, %{c.credit | backing: []}, c.lease, self())

      assert {:error, {:limit, :backing_capacity}} =
               StagedIO.encode(plan, analysis, original, bound, no_backing)

      root = :binary.copy("x", 1_100_000)
      view = binary_part(root, 0, 100_000)
      assert :binary.referenced_byte_size(view) > byte_size(view)
      {:ok, source} = StagedIO.plan_source("borrowed.bin", view, make_ref())

      assert {:error, {:limit, :backing_capacity}} =
               StagedIO.write(source, view, c.fs, overlap_only)

      assert {:ok, backing_only} =
               StagedIO.funding(c.ledger, %{c.credit | retained: []}, c.lease, self())

      assert {:error, {:limit, :backing_capacity}} =
               StagedIO.write(source, view, c.fs, backing_only)

      assert :ok = Store.release_resource(hd(c.credit.backing))
      assert {:error, :stale_resource} = StagedIO.authorized(c.funding, 0)
      assert {:error, :unfunded} = StagedIO.funding(c.ledger, c.credit, c.lease, self())
    end)
  end

  test "unavailable baseline and converted root keep the original seeded pipeline" do
    with_context(fn c ->
      unavailable = 6_000_000

      {analysis, original, bound} =
        analyze(~s|<a href="/seed">seed</a>|, "text/html", fn _ -> nil end, unavailable)

      assert {:ok, funding} =
               StagedIO.funding(c.ledger, %{c.credit | unavailable: unavailable}, c.lease, self())

      assert {:ok, plan} =
               StagedIO.plan_metadata(
                 "seed.etf",
                 analysis,
                 original,
                 bound,
                 :css_final,
                 make_ref(),
                 %{unavailable: unavailable, root: :borrowed}
               )

      assert {:error, :funding_lineage_mismatch} =
               StagedIO.encode(plan, analysis, original, bound, c.funding)

      {:ok, plan, bytes, _} = StagedIO.encode(plan, analysis, original, bound, funding)
      {:ok, _} = StagedIO.write(plan, bytes, c.fs, funding)
      {:ok, replay} = StagedIO.replay(plan, c.receipt, funding)
      assert replay.bound.budget.retained >= unavailable

      assert replay.bound.budget.retained ==
               unavailable + plan.read_capacity -
                 elem(StagedIO.measure(Map.delete(original, :budget), plan.decoded_bytes), 1)

      assert replay.bound.budget.limit == 16_000_000
      assert replay.bound.budget.counts == bound.budget.counts

      opts =
        Map.merge(@analysis_limits, %{
          content_type: "text/javascript",
          headers: [{"content-type", "text/javascript; charset=windows-1252"}],
          url: "https://example.test/script.js",
          javascript_goal: :script
        })

      seed = Crawler.Analysis.Budget.new(@analysis_limits)

      {:ok, source, seed} =
        Crawler.Charset.decode_result(<<"const x = '", 0xE9, "';">>, opts, seed)

      assert seed.retained >= byte_size(source)
      {:ok, converted} = Analysis.analyze(source, opts, seed)
      {:ok, original} = Analysis.occurrences_result(converted, opts)
      {:ok, bound} = Analysis.bind(original, fn _ -> nil end)

      assert {:ok, funding} =
               StagedIO.funding(c.ledger, %{c.credit | backing: []}, c.lease, self())

      {:ok, plan} =
        StagedIO.plan_metadata("converted.etf", converted, original, bound, nil, make_ref(), %{
          unavailable: 0,
          root: :retained
        })

      assert {:ok, _, _, _} = StagedIO.encode(plan, converted, original, bound, funding)
      {:ok, source_plan} = StagedIO.plan_source("converted.source", source, make_ref(), :retained)
      assert {:ok, _} = StagedIO.write(source_plan, source, c.fs, funding)
      {:ok, borrowed_plan} = StagedIO.plan_source("unpaid.source", source, make_ref())

      assert {:error, {:limit, :backing_capacity}} =
               StagedIO.write(borrowed_plan, source, c.fs, funding)
    end)
  end

  test "complete CSS revision vectors use the existing metadata budget" do
    with_context(fn c ->
      {analysis, original, bound} =
        analyze("<p>vector</p>", "text/html", fn _ -> nil end)

      revisions = for serial <- 1..12, do: {make_ref(), serial}
      assert :erlang.external_size(revisions) > 256

      assert {:ok, plan} =
               plan_metadata("vector.etf", analysis, original, bound, revisions, make_ref())

      assert plan.css_revision === revisions
      assert {:ok, plan, bytes, _} = StagedIO.encode(plan, analysis, original, bound, c.funding)
      assert {:ok, _} = StagedIO.write(plan, bytes, c.fs, c.funding)
      assert {:ok, replay} = StagedIO.replay(plan, c.receipt, c.funding)
      assert replay.css_revision === revisions
      assert replay.bound.budget.counts === bound.budget.counts
      assert replay.bound.budget.limit === bound.budget.limit
      assert replay.bound.budget.caps === bound.budget.caps

      too_large = List.duplicate(:binary.copy("x", 1_000_000), 20)

      assert {:error, {:limit, :analysis_bytes}} =
               plan_metadata("large.etf", analysis, original, bound, too_large, make_ref())

      for invalid <- [self(), fn -> :not_metadata end] do
        assert {:error, :unsupported_metadata} =
                 plan_metadata("invalid.etf", analysis, original, bound, invalid, make_ref())
      end
    end)
  end

  test "a later capacity exclusion preserves the earlier lexical capsule during replay" do
    with_context(fn c ->
      {analysis, original, _bound} =
        analyze(~s|<a href="/later">later</a>|, "text/html", fn _ -> nil end)

      unavailable = 6_000_000
      assert {:ok, advanced} = Crawler.Analysis.Budget.charge(original.budget, unavailable)
      original = %{original | budget: advanced}
      assert {:ok, bound} = Analysis.bind(original, fn _ -> nil end)
      assert analysis.budget.retained < unavailable

      assert {:ok, funding} =
               StagedIO.funding(c.ledger, %{c.credit | unavailable: unavailable}, c.lease, self())

      assert {:ok, plan} =
               StagedIO.plan_metadata("later.etf", analysis, original, bound, nil, make_ref(), %{
                 unavailable: unavailable,
                 root: :borrowed
               })

      assert plan.analysis_budget === analysis.budget
      assert plan.original_budget === original.budget
      assert plan.bound_budget === bound.budget

      assert {:ok, short} =
               Store.reserve_resource(c.opts, :analysis, bound.budget.retained - unavailable - 1)

      try do
        assert {:ok, short_funding} =
                 Store.resource_funding(c.opts, %{
                   c.credit
                   | retained: [short],
                     unavailable: unavailable
                 })

        assert {:error, {:limit, :retained_capacity}} =
                 StagedIO.encode(plan, analysis, original, bound, short_funding)
      after
        Store.release_resource(short)
      end

      assert {:ok, plan, bytes, _} = StagedIO.encode(plan, analysis, original, bound, funding)
      assert {:ok, _} = StagedIO.write(plan, bytes, c.fs, funding)
      assert {:ok, replay} = StagedIO.replay(plan, c.receipt, funding)
      assert replay.bound.budget.retained >= unavailable
      assert replay.bound.budget.counts === bound.budget.counts
      assert replay.bound.budget.peak >= bound.budget.peak
      assert replay.original_budget === original.budget

      assert {:error, :invalid_lineage} =
               StagedIO.plan_metadata(
                 "unfunded.etf",
                 analysis,
                 original,
                 bound,
                 nil,
                 make_ref(),
                 %{
                   unavailable: bound.budget.retained + 1,
                   root: :borrowed
                 }
               )
    end)
  end

  test "a cached physical source uses the new holder grant, not its ended origin lease" do
    scope = make_ref()

    opts =
      %{
        scope: scope,
        url: "https://example.test/imported.js",
        respect_robots: false,
        javascript_goal: :script
      }
      |> Crawler.Options.assign_defaults()
      |> Store.bind_run()

    caller = self()
    first = make_ref()
    second = make_ref()
    deadline = Crawler.Deadline.after_ms(5000, :attempt)

    try do
      assert :ok =
               Execution.run(opts, fn bound ->
                 {:ok, prepared} = Crawler.Fetcher.Requester.prepare(bound)
                 {:ok, claim, :fetch, admitted} = Store.admit_direct(bound, prepared, deadline)

                 try do
                   assert admitted.scheduler_mode == :fetch

                   assert {:ok, resource} =
                            Store.reserve_resource(bound, :response, 4096, Process.whereis(Store))

                   source_revision = make_ref()

                   source =
                     Req.Response.new(status: 200, body: "const x = 1;")
                     |> Req.Response.put_private(:crawler_source_revision, source_revision)
                     |> Req.Response.put_private(
                       :crawler_reuse,
                       %Crawler.Fetcher.Requester.PreparedRequest.ReuseDisposition{
                         dependency: :initial,
                         disposition: :candidate
                       }
                     )

                   assert Crawler.Fetcher.Requester.reuse_disposition(source).disposition ==
                            :candidate

                   {:ok, retained_bytes} = Crawler.Store.Retained.bytes(source, 4096)

                   {:ok, ancillary_bytes} =
                     Crawler.Store.Retained.bytes(%{source | body: nil}, 4096)

                   assert :ok =
                            Store.commit_response_resource(
                              resource,
                              retained_bytes,
                              ancillary_bytes + min(byte_size(source.body), 64)
                            )

                   assert :ok = Store.publish_source(admitted, resource, source)

                   assert :sys.get_state(Store).scheduler.representations[
                            admitted.representation_id
                          ].status == :ready

                   send(
                     caller,
                     {first, resource, bound.execution_lease, source_revision, prepared,
                      admitted.representation_id}
                   )

                   :ok
                 after
                   Store.complete_job(claim, Outcome.new(:succeeded))
                 end
               end)

      assert_receive {^first, source_receipt, old_lease, source_revision, prepared,
                      representation}

      opts = Map.put(opts, :javascript_goal, :module)

      assert :ok =
               Execution.run(opts, fn bound ->
                 assert :sys.get_state(Store).scheduler.representations[representation].status ==
                          :ready

                 assert :sys.get_state(Store).scheduler.initial_sources[
                          {{bound.scope, bound.generation}, prepared.equivalence}
                        ] == representation

                 {:ok, claim, :fetch, admitted} = Store.admit_direct(bound, prepared, deadline)

                 try do
                   refute Authority.execution_current?(old_lease)
                   assert admitted.scheduler_mode == :interpret
                   assert {:ok, source} = Store.response_source(admitted)
                   assert source.private.crawler_source_revision == source_revision
                   assert {:ok, overlap} = Store.reserve_resource(bound, :snapshot, 100_000)

                   try do
                     ledger = :sys.get_state(Store).resources
                     record = Resources.receipt(ledger, source_receipt)
                     assert record.lease == old_lease
                     assert record.lease != bound.execution_lease
                     assert record.holders[self()].lease == bound.execution_lease
                     assert record.holders[self()].arena != record.arena

                     credit = %{
                       retained: [],
                       backing: [source_receipt],
                       overlap: overlap,
                       unavailable: 0
                     }

                     assert {:ok, funding} =
                              StagedIO.funding(ledger, credit, bound.execution_lease, self())

                     assert :ok = StagedIO.authorized(funding, 100_000)
                     send(caller, {second, :callback_ran})
                     :ok
                   after
                     Store.release_resource(overlap)
                     Store.release_resource(source_receipt)
                   end
                 after
                   Store.complete_job(claim, Outcome.new(:succeeded))
                 end
               end)

      assert_receive {^second, :callback_ran}
    after
      Store.dispose_scope(scope)
    end
  end

  test "fresh replay credit replaces an ended producer without historical grants" do
    with_context(fn c ->
      parent = self()
      marker = make_ref()
      opts = Map.drop(c.opts, [:execution_lease, :crawler_deadline])

      {producer, monitor} =
        spawn_monitor(fn ->
          result =
            Execution.run(opts, fn bound ->
              {:ok, retained} = Store.reserve_resource(bound, :analysis, 3_000_000)
              {:ok, backing} = Store.reserve_resource(bound, :response, 1_000_000)
              {:ok, overlap} = Store.reserve_resource(bound, :snapshot, 2_000_000)

              try do
                credit = %{
                  retained: [retained],
                  backing: [backing],
                  overlap: overlap,
                  unavailable: 0
                }

                {:ok, funding} =
                  StagedIO.funding(
                    :sys.get_state(Store).resources,
                    credit,
                    bound.execution_lease,
                    self()
                  )

                {analysis, original, collection} =
                  analyze(~s|<a href="/ended">end</a>|, "text/html", fn _ -> nil end)

                {:ok, plan} =
                  plan_metadata("ended.etf", analysis, original, collection, nil, make_ref())

                {:ok, plan, bytes, _} =
                  StagedIO.encode(plan, analysis, original, collection, funding)

                {:ok, _} = StagedIO.write(plan, bytes, c.fs, funding)

                send(
                  parent,
                  {marker, plan, collection.budget.counts, collection.budget.peak,
                   [retained, backing, overlap]}
                )

                :ok
              after
                for ref <- [retained, backing, overlap], do: Store.release_resource(ref)
              end
            end)

          send(parent, {marker, :execution_result, result})
        end)

      assert_receive {^marker, plan, counts, peak, historical}, 2000
      assert_receive {^marker, :execution_result, :ok}, 2000
      assert_receive {:DOWN, ^monitor, :process, ^producer, :normal}, 2000
      ledger = :sys.get_state(Store).resources
      for ref <- historical, do: assert(Resources.receipt(ledger, ref) == nil)

      assert {:ok, funding} =
               StagedIO.funding(
                 ledger,
                 %{retained: [], backing: [], overlap: c.resource, unavailable: 0},
                 c.lease,
                 self()
               )

      assert {:ok, replay} = StagedIO.replay(plan, c.receipt, funding)
      assert replay.bound.budget.counts == counts
      assert replay.bound.budget.peak >= peak
      assert replay.bound.budget.caps == plan.bound_budget.caps
      assert replay.bound.budget.limit == plan.bound_budget.limit
    end)
  end

  test "real disk replay preserves immutable capsules, counts and revisions" do
    with_context(fn c ->
      {analysis, original, bound} =
        analyze(~s|<a href="/missing#frag">x</a>|, "text/html", fn _ -> nil end)

      {:ok, plan} =
        plan_metadata(
          "analysis.etf",
          analysis,
          original,
          bound,
          :settled_css,
          make_ref()
        )

      {:ok, plan, bytes, encoded_budget} =
        StagedIO.encode(plan, analysis, original, bound, c.funding)

      assert encoded_budget.counts == bound.budget.counts
      assert {:ok, ack} = StagedIO.write(plan, bytes, c.fs, c.funding)
      assert ack.plan == plan
      assert {:ok, replay} = StagedIO.replay(plan, c.receipt, c.funding)
      assert :erlang.binary_to_term(bytes).original.occurrences == original.occurrences
      assert replay.bound.occurrences == bound.occurrences
      assert replay.analysis.revision == analysis.revision
      assert replay.css_revision == :settled_css
      assert replay.original_budget == original.budget
      assert replay.bound.budget.counts == bound.budget.counts
      assert replay.bound.budget.limit == 16_000_000

      {:ok, original_bytes} = StagedIO.measure(Map.delete(original, :budget), plan.decoded_bytes)

      assert replay.bound.budget.retained ==
               plan.decoded_bytes + plan.bytes - original_bytes

      assert replay.bound.budget.retained <
               bound.budget.retained + plan.decoded_bytes + plan.bytes

      assert {:ok, _} = Analysis.continuation_budget(replay.analysis, replay.bound)
      assert replay.bound.budget.peak >= bound.budget.peak
      assert c.funding.overlap_capacity == 18_000_000
      assert c.funding.retained_capacity == 10_000_000
      assert c.funding.backing_capacity == 1_000_000
      assert 29_000_000 <= c.envelope
    end)
  end

  test "1000 references survive same 16 MB pipeline without counter duplication" do
    with_context(fn c ->
      source = Enum.map_join(1..1000, fn n -> ~s|<a href="/page#{n}">link</a>| end)
      {analysis, original, bound} = analyze(source, "text/html", fn _ -> nil end)
      assert length(original.occurrences) == 1000
      {:ok, plan} = plan_metadata("many.etf", analysis, original, bound, nil, make_ref())
      {:ok, plan, bytes, _} = StagedIO.encode(plan, analysis, original, bound, c.funding)
      {:ok, _} = StagedIO.write(plan, bytes, c.fs, c.funding)
      assert {:ok, replay} = StagedIO.replay(plan, c.receipt, c.funding)
      assert replay.bound.budget.counts.occurrences == 1000
      assert replay.bound.budget.counts == bound.budget.counts

      assert {:ok, output, stats} =
               Analysis.render_with_stats(replay.analysis, replay.bound, fn ref ->
                 {:online, ref.url}
               end)

      refute output =~ "https://user:secret@example.test/page1000"
      assert output =~ "https://example.test/page1000"
      assert stats.budget.limit == 16_000_000
      assert stats.budget.counts.occurrences == 1000
      assert stats.budget.peak <= 16_000_000
    end)
  end

  test "sharing amplification and expanded metadata use explicit limits" do
    with_context(fn c ->
      {analysis, original, bound} = analyze("<p>x</p>", "text/html", fn _ -> nil end)
      shared = String.duplicate("x", 80_000)
      original = Map.put(original, :shared_fixture, List.duplicate(shared, 220))
      bound = Map.put(bound, :shared_fixture, original.shared_fixture)

      assert {:error, {:limit, :analysis_bytes}} =
               plan_metadata("amplified.etf", analysis, original, bound, nil, make_ref())

      refute File.exists?(Path.join(c.receipt.stage, "metadata/amplified.etf"))

      {analysis, original, bound} = analyze(~s|<a href="/x">x</a>|, "text/html", fn _ -> nil end)

      {:ok, plan} =
        plan_metadata("small.etf", analysis, original, bound, nil, make_ref())

      {:ok, plan, bytes, _} = StagedIO.encode(plan, analysis, original, bound, c.funding)
      {:ok, _} = StagedIO.write(plan, bytes, c.fs, c.funding)

      assert {:ok, narrow} = Store.reserve_resource(c.opts, :snapshot, plan.read_capacity)

      try do
        assert {:ok, funding} =
                 StagedIO.funding(
                   :sys.get_state(Store).resources,
                   %{c.credit | overlap: narrow},
                   c.lease,
                   self()
                 )

        assert {:error, {:limit, :receipt_capacity}} = StagedIO.replay(plan, c.receipt, funding)
      after
        Store.release_resource(narrow)
      end

      assert {:error, {:limit, :analysis_bytes}} =
               StagedIO.replay(
                 %{plan | bound_budget: %{plan.bound_budget | limit: plan.read_capacity}},
                 c.receipt,
                 c.funding
               )
    end)
  end

  test "released real receipt fences IO and delivered payloads" do
    with_context(fn c ->
      {:ok, plan} = StagedIO.plan_source("one.bin", "one", make_ref())

      message =
        {:crawler_resource_delivery, c.resource, c.lease, self(), make_ref(),
         {:source, plan, "one"}}

      assert {:ok, {:source, ^plan, "one"}, _} = StagedIO.delivery(message, c.funding)

      assert {:error, :invalid_delivery} =
               StagedIO.delivery(put_elem(message, 1, make_ref()), c.funding)

      assert :ok = Store.release_resource(c.resource)
      assert Authority.execution_current?(c.lease, self())
      assert {:error, :stale_resource} = StagedIO.delivery(message, c.funding)
      assert {:error, :stale_resource} = StagedIO.write(plan, "one", c.fs, c.funding)
      refute File.exists?(Path.join(c.receipt.stage, "source/one.bin"))

      assert {:error, :unfunded} =
               StagedIO.funding(c.ledger, %{c.credit | overlap: make_ref()}, c.lease, self())
    end)
  end

  test "IO-worker delivery adopts a real prepaid grant and returns only a staged acknowledgement" do
    with_context(fn c ->
      executor = self()
      barrier = make_ref()
      filesystem = c.fs
      lease = c.lease
      owner = Process.whereis(Store)
      for receipt <- c.resources, do: assert(:ok == Store.release_resource(receipt))
      {:ok, plan} = StagedIO.plan_source("transport.bin", "one", make_ref())

      {:ok, payload_bytes} =
        Crawler.Store.Retained.bytes({:write, plan, "one"}, c.opts.max_analysis_bytes)

      {:ok, backing} = Store.reserve_resource(c.opts, :response, plan.root_bytes)
      {:ok, resource} = Store.reserve_resource(c.opts, :snapshot, payload_bytes)
      assert :ok = Store.commit_resource(backing, plan.root_bytes)
      assert :ok = Store.commit_resource(resource, payload_bytes)
      credit = %{retained: [], backing: [backing], overlap: resource, unavailable: 0}

      {worker, monitor} =
        spawn_monitor(fn ->
          receive do
            {:funding, funding} ->
              receive do
                {:crawler_resource_delivery, _, _, _, _, _} = message ->
                  StagedIO.perform_delivery(message, funding, filesystem, owner)
                  ledger = :sys.get_state(Store).resources
                  receipt = Resources.receipt(ledger, resource)

                  send(
                    executor,
                    {barrier, Map.has_key?(receipt.holders, self()),
                     Resources.holder_size(ledger, self()),
                     Authority.resource_current?(resource, lease, self())}
                  )

                  receive do
                    :stop -> :ok
                  end

                :stop ->
                  :ok
              end

            :stop ->
              :ok
          end
        end)

      try do
        for ref <- [backing, resource], do: assert(:ok == Store.retain_resource(ref, worker))
        ledger = :sys.get_state(Store).resources
        assert Resources.receipt(ledger, resource).holders[worker].status == :pending
        assert {:ok, funding} = StagedIO.funding(ledger, credit, c.lease, worker)
        send(worker, {:funding, funding})
        assert {:ok, ref} = Store.deliver_resource(resource, worker, {:write, plan, "one"})
        assert_receive {^ref, {:ok, %StagedIO.Ack{plan: ^plan}}}, 1000
        assert_receive {^barrier, false, 0, false}, 1000
        assert File.read!(Path.join(c.receipt.stage, "source/transport.bin")) == "one"
      after
        send(worker, :stop)
        assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1000
        for receipt <- [backing, resource], do: Store.release_resource(receipt)
      end
    end)
  end

  test "empty staged sources retain digest, size and existence checks" do
    with_context(fn c ->
      {:ok, plan} = StagedIO.plan_source("empty.source", "", make_ref())
      assert {:ok, _} = StagedIO.write(plan, "", c.fs, c.funding)
      assert {:ok, ""} = StagedIO.read(plan, c.receipt, c.funding)

      assert {:error, :digest_mismatch} =
               StagedIO.read(%{plan | digest: :crypto.hash(:sha256, "x")}, c.receipt, c.funding)

      assert {:error, :size_mismatch} =
               StagedIO.read(%{plan | bytes: 1}, c.receipt, c.funding)

      File.rm!(Path.join(c.receipt.stage, "source/empty.source"))
      assert {:error, :enoent} = StagedIO.read(plan, c.receipt, c.funding)
    end)
  end

  test "disk metadata rejects corruption, compression, stale budget and symlink substitution" do
    with_context(fn c ->
      {analysis, original, bound} = analyze("<p>x</p>", "text/html", fn _ -> nil end)

      {:ok, plan} =
        plan_metadata("integrity.etf", analysis, original, bound, nil, make_ref())

      {:ok, plan, bytes, _} = StagedIO.encode(plan, analysis, original, bound, c.funding)
      {:ok, _} = StagedIO.write(plan, bytes, c.fs, c.funding)
      path = Path.join(c.receipt.stage, "metadata/integrity.etf")

      assert {:error, :metadata_capsule_mismatch} =
               StagedIO.replay(
                 %{plan | original_budget: %{plan.original_budget | retained: 0}},
                 c.receipt,
                 c.funding
               )

      assert {:error, :metadata_capsule_mismatch} =
               StagedIO.replay(
                 %{plan | css_revision: :superseded},
                 c.receipt,
                 c.funding
               )

      last = :binary.last(bytes)
      File.write!(path, binary_part(bytes, 0, byte_size(bytes) - 1) <> <<Bitwise.bxor(last, 1)>>)
      assert {:error, :digest_mismatch} = StagedIO.replay(plan, c.receipt, c.funding)

      compressed = :erlang.term_to_binary(:erlang.binary_to_term(bytes), [:compressed])
      File.write!(path, compressed)

      compressed_plan = %{
        plan
        | bytes: byte_size(compressed),
          digest: :crypto.hash(:sha256, compressed)
      }

      assert {:error, :compressed_metadata} =
               StagedIO.replay(compressed_plan, c.receipt, c.funding)

      File.rm!(path)
      outside = Path.join(c.root, "unrelated")
      File.write!(outside, bytes)
      File.ln_s!(outside, path)
      assert {:error, :unsafe_path} = StagedIO.replay(plan, c.receipt, c.funding)
      assert File.read!(outside) == bytes
    end)
  end

  test "real cyclic finalization fixes paths before rendering and promotes only complete coverage" do
    with_context(fn c ->
      first = job(c)
      second = job(c)
      {:ok, session} = Session.admit(c.session, c.epoch, first)
      {:ok, session} = Session.admit(session, c.epoch, second)
      first_source = ~s|<a href="/second#section">next</a><a href="/absent">online</a>|
      second_source = ~s|<a href="/first">back</a>|

      session =
        resource(c, session, first, first_source, "text/html", "a", fn ref ->
          if String.starts_with?(ref.value, "/second"), do: second.id, else: nil
        end)

      session =
        resource(c, session, second, second_source, "text/html", "b", fn _ -> first.id end)

      finalizer = Job.new(:finalize, c.authority, %{})
      seal = make_ref()
      {:ok, snapshot, session} = Session.seal(session, c.epoch, seal, finalizer)
      assert length(Manifest.artifacts(snapshot)) == 2
      refute File.exists?(Path.join(c.root, "archive"))

      session =
        Enum.reduce([second.id, first.id], session, fn target, session ->
          {:ok, bytes, _stats} =
            Finalizer.render(snapshot, target, session.staged, c.receipt, c.funding)

          if target == first.id do
            assert bytes =~ "./#{String.duplicate("b", 24)}.html#section"
            assert bytes =~ "https://example.test/absent"
          else
            assert bytes =~ "./#{String.duplicate("a", 24)}.html"
          end

          refute bytes =~ "secret"
          assert String.starts_with?(bytes, <<0xEF, 0xBB, 0xBF>>)
          {:ok, plan} = Finalizer.plan_output(snapshot, target, bytes)
          {session, operation} = stage(c, session, plan, bytes)
          {:ok, session} = Session.rendered(session, c.epoch, seal, target, operation)
          session
        end)

      {:ok, plan, bytes} =
        Finalizer.public_manifest(snapshot, @limits.max_manifest_bytes, c.funding)

      refute bytes =~ "secret"
      {session, manifest_operation} = stage(c, session, plan, bytes)

      assert :ok =
               Session.validate_commit(session, c.epoch, seal, finalizer.id, manifest_operation)

      {:ok, prepared} = FS.prepare(c.fs)
      assert :ok = FS.promote(prepared)
      assert {:ok, ready} = Session.promoted(session, manifest_operation, Outcome.new(:succeeded))
      assert Session.status(ready).state == :ready
      assert ready.finalizer.outcome.status == :succeeded
      assert {:error, _} = Session.terminate(ready, Outcome.new(:failed))
      assert {:error, :closed} = FS.promote(prepared)
      assert {:ok, :promoted} = FS.finish(c.fs)
      assert File.exists?(Path.join(c.root, "archive/manifest.json"))
      assert {:error, :destination_exists} = FS.acquire(c.root, "archive")
    end)
  end

  test "response MIME controls copy paths and incomplete/cancelled finalization never promotes" do
    with_context(fn c ->
      target = job(c)
      {:ok, session} = Session.admit(c.session, c.epoch, target)
      bytes = <<1, 2, 3>>
      {:ok, plan} = StagedIO.plan_source("binary.bin", bytes, make_ref())
      {session, source_operation} = stage(c, session, plan, bytes)

      {:ok, session} =
        Session.response(
          session,
          c.epoch,
          target.id,
          source_operation,
          "text/css",
          "https://user:secret@example.test/wrong.jpg"
        )

      {:ok, session} = Session.copy(session, c.epoch, target.id, String.duplicate("c", 24))
      {:ok, session} = Session.settle(session, c.epoch, target.id, Outcome.new(:succeeded))
      finalizer = Job.new(:finalize, c.authority, %{})
      {:ok, snapshot, session} = Session.seal(session, c.epoch, :seal, finalizer)
      assert snapshot.artifacts[target.id].path =~ ".css"

      assert {:ok, ^bytes, nil} =
               Finalizer.render(snapshot, target.id, session.staged, c.receipt, c.funding)

      assert {:error, :unrendered_artifact} =
               Session.validate_commit(session, c.epoch, :seal, finalizer.id, make_ref())

      assert {:error, :source_revision_mismatch} =
               Finalizer.render(
                 snapshot,
                 target.id,
                 Map.put(session.staged, source_operation, %{plan | source_revision: <<0>>}),
                 c.receipt,
                 c.funding
               )

      {:ok, prepared} = FS.prepare(c.fs)
      assert :ok = FS.cancel(prepared)
      {:ok, session} = Session.terminate(session, Outcome.new(:cancelled))
      assert session.finalizer.outcome.status == :cancelled
      assert {:error, :closed} = FS.promote(prepared)
      assert {:ok, :aborted} = FS.finish(c.fs)
      refute File.exists?(Path.join(c.root, "archive"))
    end)
  end

  test "one caller-owned physical source token supports separate classic/module analyses" do
    with_context(fn c ->
      first = job(c)
      second = %{job(c) | representation_id: first.representation_id}
      {:ok, session} = Session.admit(c.session, c.epoch, first)
      {:ok, session} = Session.admit(session, c.epoch, second)
      source = ~s|import("./child");|
      source_revision = make_ref()
      {:ok, plan} = StagedIO.plan_source("shared.source", source, source_revision)
      {session, source_operation} = stage(c, session, plan, source)

      {:ok, session} =
        Session.response(
          session,
          c.epoch,
          first.id,
          source_operation,
          "text/javascript",
          "https://user:secret@example.test/wrong.css"
        )

      session =
        Enum.reduce([{first, :script, "s"}, {second, :module, "m"}], session, fn {target, goal,
                                                                                  letter},
                                                                                 session ->
          opts =
            Map.merge(@analysis_limits, %{
              url: "https://example.test/script",
              referrer_url: "https://example.test/script",
              content_type: "text/javascript",
              javascript_goal: goal,
              assets: ["js"]
            })

          {:ok, analysis} = Analysis.analyze(source, opts)
          {:ok, original} = Analysis.occurrences_result(analysis, opts)
          {:ok, bound} = Analysis.bind(original, fn _ -> nil end)

          {:ok, plan} =
            plan_metadata(
              letter <> ".etf",
              analysis,
              original,
              bound,
              nil,
              source_revision
            )

          {:ok, plan, bytes, _} = StagedIO.encode(plan, analysis, original, bound, c.funding)
          {session, metadata_operation} = stage(c, session, plan, bytes)

          assert {:error, :changed_occurrence_collection} =
                   Session.interpretation(
                     session,
                     c.epoch,
                     target.id,
                     metadata_operation,
                     String.duplicate(letter, 24),
                     StagedIO.compact_edges(
                       Enum.map(bound.occurrences, &%{&1 | target: make_ref()})
                     )
                   )

          {:ok, session} =
            Session.interpretation(
              session,
              c.epoch,
              target.id,
              metadata_operation,
              String.duplicate(letter, 24),
              StagedIO.compact_edges(bound.occurrences)
            )

          {:ok, session} = Session.settle(session, c.epoch, target.id, Outcome.new(:succeeded))
          session
        end)

      {:ok, snapshot, session} =
        Session.seal(session, c.epoch, :seal, Job.new(:finalize, c.authority, %{}))

      assert snapshot.artifacts[first.id].source_revision == source_revision
      assert snapshot.artifacts[second.id].source_revision == source_revision

      refute snapshot.artifacts[first.id].analysis_revision ==
               snapshot.artifacts[second.id].analysis_revision

      assert snapshot.artifacts[first.id].source_handle ==
               snapshot.artifacts[second.id].source_handle

      for target <- [first.id, second.id] do
        assert snapshot.artifacts[target].path =~ ".js"

        assert {:ok, output, _} =
                 Finalizer.render(snapshot, target, session.staged, c.receipt, c.funding)

        assert output =~ "https://example.test/child"
      end

      refute inspect(Manifest.public_manifest(snapshot)) =~ "secret"
    end)
  end

  test "standalone publication returns a per-file result and cannot intrude on a managed claim" do
    with_context(fn c ->
      assert {:error, :destination_owned} =
               FS.publish_file(c.root, "archive/intrude.css", "x",
                 owner: self(),
                 max_bytes: 1024,
                 max_file_bytes: 512,
                 max_metadata_bytes: 512,
                 max_files: 10,
                 max_entries: 40,
                 max_journal_bytes: 16384
               )

      assert :ok =
               FS.publish_file(c.root, "solo.css", "body {}",
                 owner: self(),
                 max_bytes: 1024,
                 max_file_bytes: 512,
                 max_metadata_bytes: 512,
                 max_files: 10,
                 max_entries: 40,
                 max_journal_bytes: 16384
               )

      assert File.read!(Path.join(c.root, "solo.css")) == "body {}"
      assert Session.status(c.session).state == :admitting
      refute File.exists?(Path.join(c.root, "archive"))
    end)
  end

  defp analyze(source, type, resolver, unavailable \\ 0) do
    opts =
      Map.merge(@analysis_limits, %{
        url: "https://user:secret@example.test/first",
        referrer_url: "https://user:secret@example.test/first",
        content_type: type,
        assets: ["css", "js", "images"],
        css_tokens: %{},
        css_references: %{},
        css_revision: :settled
      })

    {:ok, seed} =
      Crawler.Analysis.Budget.charge(Crawler.Analysis.Budget.new(@analysis_limits), unavailable)

    {:ok, analysis} = Analysis.analyze(source, opts, seed)
    {:ok, original} = Analysis.occurrences_result(analysis, opts)
    {:ok, bound} = Analysis.bind(original, resolver)
    {analysis, original, bound}
  end

  defp resource(c, session, target, source, type, letter, resolver) do
    {:ok, plan} = StagedIO.plan_source(letter <> ".source", source, make_ref())
    {session, source_operation} = stage(c, session, plan, source)

    {:ok, session} =
      Session.response(
        session,
        c.epoch,
        target.id,
        source_operation,
        type,
        "https://user:secret@example.test/" <> letter
      )

    {analysis, original, bound} = analyze(source, type, resolver)

    {:ok, plan} =
      plan_metadata(
        letter <> ".etf",
        analysis,
        original,
        bound,
        :settled,
        session.staged[source_operation].source_revision
      )

    {:ok, plan, bytes, _} = StagedIO.encode(plan, analysis, original, bound, c.funding)
    {session, metadata_operation} = stage(c, session, plan, bytes)

    {:ok, session} =
      Session.interpretation(
        session,
        c.epoch,
        target.id,
        metadata_operation,
        String.duplicate(letter, 24),
        StagedIO.compact_edges(bound.occurrences)
      )

    {:ok, session} = Session.settle(session, c.epoch, target.id, Outcome.new(:succeeded))
    session
  end

  defp plan_metadata(path, analysis, original, bound, css, source) do
    StagedIO.plan_metadata(path, analysis, original, bound, css, source, %{
      unavailable: 0,
      root: :borrowed
    })
  end

  defp stage(c, session, plan, bytes) do
    operation = make_ref()
    {:ok, session} = Session.reserve(session, c.epoch, operation, plan)
    {:ok, ack} = StagedIO.write(plan, bytes, c.fs, c.funding)
    {:ok, session} = Session.written(session, c.epoch, operation, ack)
    {session, operation}
  end

  defp job(c),
    do:
      Job.new(:fetch, c.authority, %{representation_id: make_ref(), interpretation_id: make_ref()})

  defp with_context(callback) do
    caller = self()
    completed = make_ref()
    scope = make_ref()
    opts = Store.bind_run(%{scope: scope, respect_robots: false})

    try do
      assert :ok =
               Execution.run(opts, fn bound ->
                 assert Authority.execution_current?(bound.execution_lease, self())
                 assert @analysis_limits.max_total_bytes <= bound.max_analysis_bytes
                 assert {:ok, resource} = Store.reserve_resource(bound, :snapshot, 18_000_000)
                 assert {:ok, retained} = Store.reserve_resource(bound, :analysis, 10_000_000)
                 assert {:ok, backing} = Store.reserve_resource(bound, :response, 1_000_000)

                 credit = %{
                   retained: [retained],
                   backing: [backing],
                   overlap: resource,
                   unavailable: 0
                 }

                 try do
                   ledger = :sys.get_state(Store).resources

                   assert {:ok, funding} =
                            StagedIO.funding(ledger, credit, bound.execution_lease, self())

                   {physical_tmp, 0} = System.cmd("pwd", ["-P"], cd: System.tmp_dir!())

                   root =
                     Path.join(
                       String.trim(physical_tmp),
                       "crawler-export-test-" <>
                         Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
                     )

                   File.mkdir!(root)

                   try do
                     File.chmod!(root, 0o700)

                     assert {:ok, fs, receipt} =
                              FS.acquire(root, "archive",
                                owner: self(),
                                max_bytes: @limits.max_staged_bytes,
                                max_file_bytes: @limits.max_file_bytes,
                                max_metadata_bytes: @limits.max_staged_metadata_bytes,
                                max_files: @limits.max_files,
                                max_entries: 1000,
                                max_journal_bytes: 1_000_000
                              )

                     try do
                       epoch = make_ref()

                       {:ok, session} =
                         Session.new(
                           String.duplicate("e", 24),
                           {scope, bound.generation},
                           epoch,
                           @limits
                         )

                       callback.(%{
                         root: root,
                         fs: fs,
                         receipt: receipt,
                         funding: funding,
                         ledger: ledger,
                         resource: resource,
                         resources: [retained, backing, resource],
                         credit: credit,
                         opts: bound,
                         lease: bound.execution_lease,
                         envelope: ResourceManager.envelope(bound),
                         epoch: epoch,
                         session: session,
                         authority: {scope, bound.generation, bound[:queue]}
                       })

                       send(caller, {completed, :callback_ran})
                       :ok
                     after
                       abort(fs)
                     end
                   after
                     File.rm_rf!(root)
                   end
                 after
                   for ref <- [retained, backing, resource], do: Store.release_resource(ref)
                 end
               end)

      assert_receive {^completed, :callback_ran}
    after
      Store.dispose_scope(scope)
    end
  end

  defp abort(fs) do
    try do
      FS.abort(fs)
    catch
      :exit, {:normal, _} -> :ok
      :exit, {:noproc, _} -> :ok
    end
  end
end
