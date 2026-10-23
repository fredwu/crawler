defmodule Crawler.Export.SessionTest do
  use ExUnit.Case, async: true

  alias Crawler.Export.Session
  alias Crawler.Export.StagedIO
  alias Crawler.Export.StagedIO.Ack
  alias Crawler.Job
  alias Crawler.Job.Outcome

  @limits %{
    max_targets: 20,
    max_representations: 20,
    max_artifacts: 20,
    max_edges: 2000,
    max_manifest_bytes: 4_000_000,
    max_staged_bytes: 32_000_000,
    max_staged_metadata_bytes: 20_000_000,
    max_file_bytes: 16_000_000,
    max_files: 100
  }

  setup do
    scope = make_ref()
    generation = {make_ref(), scope, make_ref()}
    authority = {scope, generation, self()}
    epoch = make_ref()
    {:ok, session} = Session.new(String.duplicate("e", 24), {scope, generation}, epoch, @limits)

    job =
      Job.new(:fetch, authority, %{representation_id: make_ref(), interpretation_id: make_ref()})

    finalizer = Job.new(:finalize, authority, %{})
    %{session: session, epoch: epoch, job: job, finalizer: finalizer}
  end

  test "canonical admission reuses a Job.id and does not invent an identity", c do
    assert {:ok, session} = Session.admit(c.session, c.epoch, c.job)
    assert {:existing, ^session} = Session.admit(session, c.epoch, c.job)
    assert Map.keys(session.manifest.targets) == [c.job.id]

    assert {:error, :target_identity_changed} =
             Session.admit(session, c.epoch, %{c.job | interpretation_id: make_ref()})

    assert {:error, :stale_epoch} = Session.admit(session, make_ref(), c.job)

    assert {:error, :stale_run} =
             Session.admit(session, c.epoch, %{
               c.job
               | authority: {make_ref(), elem(c.job.authority, 1), self()}
             })
  end

  test "both serial admission/seal orders have defined outcomes", c do
    {:ok, session} = Session.admit(c.session, c.epoch, c.job)
    assert {:error, :pending_outcomes} = Session.seal(session, c.epoch, make_ref(), c.finalizer)
    {:ok, session} = Session.settle(session, c.epoch, c.job.id, Outcome.new(:rejected))
    assert {:ok, _, sealed} = Session.seal(session, c.epoch, make_ref(), c.finalizer)
    assert {:error, :closed_export} = Session.admit(sealed, c.epoch, c.job)

    assert {:ok, _, sealed_first} = Session.seal(c.session, c.epoch, make_ref(), c.finalizer)
    assert {:error, :closed_export} = Session.admit(sealed_first, c.epoch, c.job)
    assert sealed_first.finalizer.id == c.finalizer.id
    assert {:error, :closed_export} = Session.seal(sealed_first, c.epoch, make_ref(), c.finalizer)
  end

  test "stale or duplicate IO acknowledgement cannot settle another reservation", c do
    operation = make_ref()
    {:ok, plan} = StagedIO.plan_source("source.bin", "source", make_ref())
    {:ok, session} = Session.reserve(c.session, c.epoch, operation, plan)
    ack = %Ack{plan: plan, ticket: make_ref()}

    assert {:error, :unencoded_plan} =
             Session.reserve(c.session, c.epoch, make_ref(), %{plan | digest: nil})

    assert {:error, :pending_io} = Session.seal(session, c.epoch, make_ref(), c.finalizer)
    assert {:error, :stale_epoch} = Session.written(session, make_ref(), operation, ack)
    assert {:error, :stale_write} = Session.written(session, c.epoch, make_ref(), ack)

    assert {:error, :stale_write} =
             Session.written(session, c.epoch, operation, %{ack | plan: %{plan | digest: <<0>>}})

    assert {:ok, session} = Session.written(session, c.epoch, operation, ack)
    assert {:error, :stale_write} = Session.written(session, c.epoch, operation, ack)
    assert session.staged[operation] == plan
    refute Map.has_key?(Map.from_struct(plan), :source)
    refute Map.has_key?(Map.from_struct(plan), :payload)
  end

  test "written stage bytes remain charged and descriptors use the same metadata bound", c do
    limits = %{@limits | max_staged_bytes: 8}
    {:ok, session} = Session.new(String.duplicate("e", 24), c.session.run, c.epoch, limits)
    {:ok, plan} = StagedIO.plan_source("one.bin", "123456", make_ref())
    operation = make_ref()
    {:ok, session} = Session.reserve(session, c.epoch, operation, plan)

    {:ok, session} =
      Session.written(session, c.epoch, operation, %Ack{plan: plan, ticket: make_ref()})

    {:ok, next} = StagedIO.plan_source("two.bin", "123", make_ref())

    assert {:error, {:limit, :max_staged_bytes}} =
             Session.reserve(session, c.epoch, make_ref(), next)

    assert session.manifest.bytes == 6

    {:ok, tiny} =
      Session.new(String.duplicate("e", 24), c.session.run, c.epoch, %{
        @limits
        | max_manifest_bytes: 10
      })

    assert {:error, {:limit, _}} = Session.reserve(tiny, c.epoch, make_ref(), plan)
  end

  test "finalizer obligation cannot become ready without output coverage", c do
    {:ok, _, session} = Session.seal(c.session, c.epoch, :seal, c.finalizer)

    assert {:error, :missing_public_manifest} =
             Session.validate_commit(session, c.epoch, :seal, c.finalizer.id, make_ref())

    assert {:error, :stale_finalizer} =
             Session.validate_commit(session, c.epoch, :seal, make_ref(), make_ref())

    assert {:error, :closed_finalizer} =
             Session.promoted(session, make_ref(), Outcome.new(:succeeded))

    assert {:ok, cancelled} = Session.terminate(session, Outcome.new(:cancelled, :run_retired))
    assert cancelled.finalizer.outcome.status == :cancelled
    assert Session.status(cancelled).state == :cancelled
    assert {:error, _} = Session.terminate(cancelled, Outcome.new(:failed))

    assert {:error, :closed_finalizer} =
             Session.promoted(cancelled, make_ref(), Outcome.new(:succeeded))
  end

  test "public status does not derive ready or expose private authority", c do
    {:ok, _, session} = Session.seal(c.session, c.epoch, make_ref(), c.finalizer)
    public = Session.status(session)
    assert public.state == :finalizing
    refute Map.has_key?(public, :epoch)
    refute Map.has_key?(public, :run)
    refute Map.has_key?(public, :finalizer)
    assert {:ok, limited} = Session.terminate(session, Outcome.limited(:max_control_documents))
    assert limited.finalizer.outcome.status == :limited
    assert Session.status(limited).state == :failed
    assert Session.status(limited).reason == :limited

    owner_status = %{
      outcome: :open,
      reported_limit: {:limit, :max_control_documents},
      running?: true,
      paused?: false,
      private: "credential"
    }

    assert {:ok, projected} = Session.status(session, owner_status)
    assert projected.run.outcome == :open
    assert projected.run.reported_limit == {:limit, :max_control_documents}
    assert projected.export.state == :finalizing
    refute inspect(projected) =~ "credential"

    assert {:ok, paused} =
             Session.status(session, %{owner_status | running?: false, paused?: true})

    assert paused.export.state == :finalizing
  end
end
