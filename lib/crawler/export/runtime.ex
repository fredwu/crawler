defmodule Crawler.Export.Runtime do
  @moduledoc """
  Funded staging steps inside one existing canonical Job execution.

  The owner supplies every integration callback. This helper does not admit,
  close, seal, promote, cancel, or publish status. Callbacks retain custody of
  all payload grants until filesystem completion or verified filesystem DOWN.
  Companion DOWN alone never establishes completion or releases custody.

  Activation arms an OTP timer from the original finite deadline so a blocked
  filesystem call can be interrupted independently of the Store owner. Its
  state contains fixed tags, PIDs, references, integer times and the deadline
  kind, within the existing 32 KiB metadata reservation. This is a bounded
  metadata tariff, not a measure of all VM allocations. Normal return cancels
  the timer. It also monitors its target and cancels after target DOWN, including
  external kill; that asynchronous cleanup can briefly outlive companion DOWN
  and does not establish filesystem DOWN.

  `reserve`, `written`, `custody`, `settled` and `abandon` return `:ok` or an
  explicit error. `deliver` returns the real delivery reference and a Funding
  capsule for the companion. The same credit roles must survive transport.
  `start_io` returns the owner-spawned companion for a startup nonce. The
  producer waits for its READY handshake before calling the body. `render_funding`
  checks the sealed finalizer's uncommitted overlap receipt; `finish_render`
  commits that receipt after the render frame ends and returns current Funding.
  Render and preparation require a finalizer Job; the owner proves the current
  claim, closed admission and sealed immutable snapshot.
  """

  alias Crawler.Deadline
  alias Crawler.Export.Filesystem
  alias Crawler.Export.Finalizer
  alias Crawler.Export.StagedIO
  alias Crawler.Export.StagedIO.Ack
  alias Crawler.Export.StagedIO.Funding
  alias Crawler.Export.StagedIO.Plan
  alias Crawler.Job
  alias Crawler.Store
  alias Crawler.Store.Authority

  @slot {__MODULE__, :active}

  defmodule Context do
    @moduledoc false
    @derive {Inspect, only: []}
    @enforce_keys [
      :job,
      :opts,
      :executor,
      :filesystem,
      :recovery_receipt,
      :resource_owner,
      :start_io,
      :render_funding,
      :finish_render,
      :reserve,
      :written,
      :custody,
      :deliver,
      :settled,
      :abandon
    ]
    defstruct @enforce_keys

    def new(opts, epoch, job, filesystem) do
      %__MODULE__{
        job: job,
        opts: opts,
        executor: self(),
        filesystem: filesystem.filesystem,
        recovery_receipt: filesystem.receipt,
        resource_owner: Process.whereis(Crawler.Store),
        start_io: &Crawler.Store.start_export_io(opts, epoch, &1),
        render_funding: &Crawler.Store.export_render_funding(opts, epoch, &1),
        finish_render: &Crawler.Store.export_finish_render(opts, epoch, &1, &2),
        reserve: &Crawler.Store.export_reserve(opts, epoch, &1, &2),
        written: &Crawler.Store.export_written(opts, epoch, &1, &2),
        custody: &Crawler.Store.export_custody(opts, epoch, &1, &2, &3),
        deliver: &Crawler.Store.export_deliver(opts, epoch, &1, &2, &3),
        settled: &Crawler.Store.export_settled(opts, epoch, &1, &2),
        abandon: &Crawler.Store.export_abandon(opts, epoch, &1, &2)
      }
    end
  end

  @derive {Inspect, only: []}
  @enforce_keys [:context, :companion, :monitor, :owner_monitor, :filesystem_monitor, :token]
  defstruct @enforce_keys

  def with_io(%Context{} = context, callback) when is_function(callback, 1) do
    with :ok <- validate(context),
         nil <- Process.get(@slot) do
      token = make_ref()
      Process.put(@slot, token)
      owner_monitor = Process.monitor(context.resource_owner)
      filesystem_monitor = Process.monitor(context.filesystem)

      try do
        case context.start_io.(token) do
          {:ok, companion} when is_pid(companion) ->
            runtime = %__MODULE__{
              context: context,
              companion: companion,
              monitor: Process.monitor(companion),
              owner_monitor: owner_monitor,
              filesystem_monitor: filesystem_monitor,
              token: token
            }

            try do
              with :ok <- await_ready(runtime),
                   :ok <- current(runtime),
                   do: callback.(runtime)
            after
              stop(runtime)
            end

          {:error, _} = error ->
            error

          _ ->
            {:error, :invalid_start_result}
        end
      after
        Process.demonitor(owner_monitor, [:flush])
        Process.demonitor(filesystem_monitor, [:flush])
        Process.delete(@slot)
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :already_running}
    end
  end

  def stage_source(runtime, path, bytes, source_revision, root_mode, %Funding{} = funding) do
    step(runtime, fn ->
      with {:ok, plan} <- StagedIO.plan_source(path, bytes, source_revision, root_mode),
           do: write_plan(runtime, plan, bytes, funding)
    end)
  end

  def stage_metadata(
        runtime,
        path,
        analysis,
        original,
        bound,
        css_revision,
        source_revision,
        lineage,
        %Funding{} = funding
      ) do
    step(runtime, fn ->
      with {:ok, plan} <-
             StagedIO.plan_metadata(
               path,
               analysis,
               original,
               bound,
               css_revision,
               source_revision,
               lineage
             ),
           {:ok, plan, bytes, _budget} <-
             StagedIO.encode(plan, analysis, original, bound, funding),
           do: write_plan(runtime, plan, bytes, funding)
    end)
  end

  def render(runtime, snapshot, target, staged, %Funding{} = funding) do
    step(runtime, fn ->
      with :ok <- finalizer(runtime),
           {:ok, %Funding{} = checked_funding} <- runtime.context.render_funding.(funding),
           true <- checked_funding === funding or {:error, :changed_render_funding},
           {:ok, bytes, stats} <-
             render_frame(
               snapshot,
               target,
               staged,
               runtime.context.recovery_receipt,
               checked_funding
             ),
           output_bytes = :binary.referenced_byte_size(bytes),
           {:ok, %Funding{} = fresh_funding} <-
             runtime.context.finish_render.(checked_funding, output_bytes),
           :ok <- finished_funding(checked_funding, fresh_funding, output_bytes),
           :ok <- current(runtime),
           {:ok, plan} <- Finalizer.plan_output(snapshot, target, bytes),
           {:ok, ack} <- write_plan(runtime, plan, bytes, fresh_funding),
           do: {:ok, ack, stats}
    end)
  end

  defp render_frame(snapshot, target, staged, receipt, funding),
    do: Finalizer.render(snapshot, target, staged, receipt, funding)

  defp finished_funding(before, fresh, bytes) do
    overlap_grant = %{Map.fetch!(before.grants, before.overlap) | capacity: bytes}

    expected = %{
      before
      | overlap_capacity: bytes,
        grants: Map.put(before.grants, before.overlap, overlap_grant)
    }

    with true <- bytes <= before.overlap_capacity or {:error, :increased_render_funding},
         true <- fresh === expected or {:error, :changed_render_funding},
         do: StagedIO.authorized(fresh, bytes)
  end

  def public_manifest(runtime, snapshot, max_manifest_bytes, %Funding{} = funding) do
    step(runtime, fn ->
      with :ok <- finalizer(runtime),
           {:ok, %Funding{} = checked_funding} <- runtime.context.render_funding.(funding),
           true <- checked_funding === funding or {:error, :changed_render_funding},
           {:ok, plan, bytes} <- manifest_frame(snapshot, max_manifest_bytes, checked_funding),
           output_bytes = :binary.referenced_byte_size(bytes),
           {:ok, %Funding{} = fresh_funding} <-
             runtime.context.finish_render.(checked_funding, output_bytes),
           :ok <- finished_funding(checked_funding, fresh_funding, output_bytes),
           :ok <- current(runtime),
           do: write_plan(runtime, plan, bytes, fresh_funding)
    end)
  end

  defp manifest_frame(snapshot, max_manifest_bytes, funding),
    do: Finalizer.public_manifest(snapshot, max_manifest_bytes, funding)

  def prepare(runtime) do
    step(runtime, fn ->
      with :ok <- finalizer(runtime) do
        reference = make_ref()
        send(runtime.companion, {:prepare, runtime.token, reference})

        case await(runtime, reference) do
          {:ok, {:crawler_filesystem_prepared, callback}} = result
          when is_function(callback, 1) ->
            result

          {:error, _} = error ->
            preparation_error(runtime, error)

          _ ->
            preparation_error(runtime, {:error, :invalid_preparation})
        end
      end
    end)
  end

  defp preparation_error(runtime, error) do
    Process.put(@slot, {runtime.token, :failed})
    error
  end

  defp finalizer(%__MODULE__{context: %{job: %Job{kind: :finalize}}}), do: :ok
  defp finalizer(_runtime), do: {:error, :wrong_job_kind}

  defp step(runtime, callback) do
    with :ok <- current(runtime),
         true <- Process.get(@slot) == runtime.token or {:error, :operation_pending} do
      Process.put(@slot, {runtime.token, :busy})

      try do
        callback.()
      after
        if Process.get(@slot) == {runtime.token, :busy}, do: Process.put(@slot, runtime.token)
      end
    end
  end

  defp write_plan(runtime, %Plan{} = plan, bytes, funding) do
    operation = make_ref()

    with :ok <- StagedIO.authorized(funding, 0) do
      try do
        with :ok <- checked(runtime.context.reserve.(operation, plan), :reserve) do
          credit = StagedIO.credit_spec(funding)

          result =
            with :ok <-
                   checked(
                     runtime.context.custody.(operation, runtime.companion, credit),
                     :custody
                   ),
                 {:ok, reference, %Funding{} = io_funding} <-
                   runtime.context.deliver.(runtime.companion, credit, {:write, plan, bytes}),
                 true <- is_reference(reference) or {:error, :invalid_delivery_reference},
                 true <-
                   io_funding.holder == runtime.companion or {:error, :wrong_delivery_holder},
                 true <-
                   io_funding.lease == runtime.context.opts.execution_lease or
                     {:error, :wrong_delivery_lease},
                 true <-
                   StagedIO.credit_spec(io_funding) == credit or
                     {:error, :changed_delivery_credit},
                 :ok <- current(runtime) do
              send(runtime.companion, {:write, runtime.token, reference, io_funding})

              with {:ok, %Ack{plan: ^plan} = ack} <- await(runtime, reference),
                   :ok <- current(runtime),
                   :ok <- checked(runtime.context.written.(operation, ack), :written),
                   :ok <- checked(runtime.context.settled.(operation, {:ok, ack}), :settled),
                   do: {:ok, %{ack | operation: operation}}
            end

          case result do
            {:ok, %Ack{plan: ^plan}} -> result
            {:ok, _} -> abandon(runtime, operation, {:error, :invalid_acknowledgement})
            {:error, _} = error -> abandon(runtime, operation, error)
            _ -> abandon(runtime, operation, {:error, :invalid_delivery_result})
          end
        end
      catch
        kind, reason ->
          abandon(runtime, operation, {:error, {:operation_raised, kind, reason}})
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp abandon(runtime, operation, reason) do
    Process.put(@slot, {runtime.token, :failed})

    case checked(runtime.context.abandon.(operation, reason), :abandon) do
      :ok -> reason
      error -> error
    end
  end

  defp checked(result, name) do
    case result do
      :ok -> :ok
      {:error, _} = error -> error
      _ -> {:error, {:invalid_callback_result, name}}
    end
  end

  defp current(%__MODULE__{} = runtime) do
    with true <-
           Process.get(@slot) in [runtime.token, {runtime.token, :busy}] or
             {:error, :inactive_runtime},
         :ok <- validate(runtime.context),
         true <- Process.alive?(runtime.context.resource_owner) or {:error, :owner_down},
         true <- Process.alive?(runtime.companion) or {:error, :companion_down},
         true <- Process.alive?(runtime.context.filesystem) or {:error, :filesystem_down},
         do: :ok
  end

  defp validate(%Context{job: %Job{} = job, opts: opts} = context) do
    authority = {opts[:scope], opts[:generation], opts[:queue]}
    lease = opts[:execution_lease]

    cond do
      context.executor != self() ->
        {:error, :wrong_executor}

      job.authority !== authority ->
        {:error, :wrong_job_authority}

      not is_reference(job.id) ->
        {:error, :invalid_job}

      not is_reference(lease) ->
        {:error, :missing_execution}

      not valid_deadline?(opts[:crawler_deadline]) ->
        {:error, :missing_deadline}

      not is_pid(context.filesystem) ->
        {:error, :invalid_filesystem}

      not is_map(context.recovery_receipt) ->
        {:error, :invalid_recovery_receipt}

      not is_pid(context.resource_owner) ->
        {:error, :invalid_resource_owner}

      not callbacks?(context) ->
        {:error, :invalid_callbacks}

      not Authority.execution_current?(lease, self()) ->
        {:error, :stale_execution}

      not Authority.current?(opts[:scope], opts[:generation], opts[:queue], lease) ->
        {:error, :stale_execution}

      true ->
        :ok
    end
  end

  defp callbacks?(context) do
    is_function(context.start_io, 1) and is_function(context.render_funding, 1) and
      is_function(context.finish_render, 2) and is_function(context.reserve, 2) and
      is_function(context.written, 2) and
      is_function(context.custody, 3) and is_function(context.deliver, 3) and
      is_function(context.settled, 2) and is_function(context.abandon, 2)
  end

  defp await_ready(runtime) do
    token = runtime.token
    companion = runtime.companion
    lease = runtime.context.opts.execution_lease
    monitor = runtime.monitor
    owner = runtime.context.resource_owner
    owner_monitor = runtime.owner_monitor
    filesystem = runtime.context.filesystem
    filesystem_monitor = runtime.filesystem_monitor

    receive do
      {:crawler_export_io_ready, ^token, ^companion, ^lease} ->
        :ok

      {:DOWN, ^monitor, :process, ^companion, reason} ->
        {:error, {:companion_down, reason}}

      {:DOWN, ^owner_monitor, :process, ^owner, reason} ->
        {:error, {:owner_down, reason}}

      {:DOWN, ^filesystem_monitor, :process, ^filesystem, reason} ->
        {:error, {:filesystem_down, reason}}
    after
      Deadline.remaining(runtime.context.opts.crawler_deadline) ->
        {:error, {:deadline, runtime.context.opts.crawler_deadline.kind}}
    end
  end

  defp await(runtime, reference) do
    companion = runtime.companion
    monitor = runtime.monitor
    owner = runtime.context.resource_owner
    owner_monitor = runtime.owner_monitor
    filesystem = runtime.context.filesystem
    filesystem_monitor = runtime.filesystem_monitor

    receive do
      {^reference, result} ->
        result

      {:DOWN, ^monitor, :process, ^companion, reason} ->
        {:error, {:companion_down, reason}}

      {:DOWN, ^owner_monitor, :process, ^owner, reason} ->
        {:error, {:owner_down, reason}}

      {:DOWN, ^filesystem_monitor, :process, ^filesystem, reason} ->
        {:error, {:filesystem_down, reason}}
    after
      Deadline.remaining(runtime.context.opts.crawler_deadline) ->
        {:error, {:deadline, runtime.context.opts.crawler_deadline.kind}}
    end
  end

  defp valid_deadline?(%Deadline{at: at, kind: kind})
       when is_integer(at) and at >= -9_223_372_036_854_775_808 and
              at <= 9_223_372_036_854_775_807 and kind in [:attempt, :run],
       do: true

  defp valid_deadline?(_), do: false

  @doc false
  def companion_start(
        executor,
        owner,
        filesystem,
        %Deadline{at: at, kind: kind} = deadline,
        nonce,
        lease
      )
      when is_pid(executor) and is_pid(owner) and is_pid(filesystem) and
             is_reference(nonce) and is_reference(lease) and is_integer(at) and
             at >= -9_223_372_036_854_775_808 and at <= 9_223_372_036_854_775_807 and
             kind in [:attempt, :run] do
    monitors = {
      Process.monitor(executor),
      Process.monitor(owner),
      Process.monitor(filesystem)
    }

    companion_activate(executor, owner, filesystem, deadline, nonce, lease, monitors)
  end

  defp companion_activate(executor, owner, filesystem, deadline, nonce, lease, monitors) do
    {executor_monitor, owner_monitor, filesystem_monitor} = monitors

    receive do
      {:crawler_export_io_activate, ^nonce, ^owner} ->
        case actor_current(executor, owner, filesystem, deadline, lease) do
          :ok -> companion_run(executor, owner, filesystem, deadline, nonce, lease, monitors)
          {:error, reason} -> exit(reason)
        end

      {:crawler_export_io_activate, _, _} ->
        companion_activate(executor, owner, filesystem, deadline, nonce, lease, monitors)

      {:stop, ^nonce} ->
        :ok

      {:DOWN, ^executor_monitor, :process, ^executor, _} ->
        :ok

      {:DOWN, ^owner_monitor, :process, ^owner, _} ->
        :ok

      {:DOWN, ^filesystem_monitor, :process, ^filesystem, _} ->
        exit(:filesystem_down)
    after
      Deadline.remaining(deadline) -> exit({:deadline, deadline.kind})
    end
  end

  defp companion_run(executor, owner, filesystem, deadline, nonce, lease, monitors) do
    case actor_timer(deadline) do
      {:ok, timer} ->
        try do
          with :ok <- actor_current(executor, owner, filesystem, deadline, lease),
               :ok <- Store.export_io_ready(owner, lease, nonce),
               :ok <- actor_current(executor, owner, filesystem, deadline, lease) do
            send(executor, {:crawler_export_io_ready, nonce, self(), lease})
            companion_loop(executor, owner, filesystem, deadline, nonce, lease, monitors)
          else
            {:error, reason} -> exit(reason)
          end
        after
          :timer.cancel(timer)
        end

      {:error, reason} ->
        exit(reason)
    end
  end

  defp actor_timer(deadline) do
    case Deadline.remaining(deadline) do
      0 ->
        exit({:deadline, deadline.kind})

      remaining ->
        # OTP's interval loop monitors this caller; one-shot exit timers do not.
        :timer.apply_interval(remaining, :erlang, :exit, [self(), {:deadline, deadline.kind}])
    end
  end

  defp companion_loop(executor, owner, filesystem, deadline, nonce, lease, monitors) do
    {executor_monitor, owner_monitor, filesystem_monitor} = monitors

    receive do
      {:write, ^nonce, reference, %Funding{lease: ^lease, holder: holder} = funding}
      when holder == self() and is_reference(reference) ->
        with :ok <- actor_current(executor, owner, filesystem, deadline, lease) do
          companion_delivery(
            executor,
            owner,
            filesystem,
            deadline,
            nonce,
            lease,
            monitors,
            reference,
            funding
          )
        else
          {:error, reason} -> exit(reason)
        end

      {:prepare, ^nonce, reference} when is_reference(reference) ->
        with :ok <- actor_current(executor, owner, filesystem, deadline, lease) do
          send(executor, {reference, Filesystem.prepare(filesystem)})
          companion_loop(executor, owner, filesystem, deadline, nonce, lease, monitors)
        else
          {:error, reason} -> exit(reason)
        end

      {:stop, ^nonce} ->
        :ok

      {:DOWN, ^executor_monitor, :process, ^executor, _} ->
        :ok

      {:DOWN, ^owner_monitor, :process, ^owner, _} ->
        :ok

      {:DOWN, ^filesystem_monitor, :process, ^filesystem, :normal} ->
        :ok

      {:DOWN, ^filesystem_monitor, :process, ^filesystem, _} ->
        exit(:filesystem_down)
    after
      Deadline.remaining(deadline) -> exit({:deadline, deadline.kind})
    end
  end

  defp companion_delivery(
         executor,
         owner,
         filesystem,
         deadline,
         nonce,
         lease,
         monitors,
         reference,
         funding
       ) do
    {executor_monitor, owner_monitor, filesystem_monitor} = monitors

    receive do
      {:crawler_resource_delivery, _, ^lease, ^executor, ^reference, _} = message ->
        with :ok <- actor_current(executor, owner, filesystem, deadline, lease) do
          StagedIO.perform_delivery(message, funding, filesystem, owner)
          companion_loop(executor, owner, filesystem, deadline, nonce, lease, monitors)
        else
          {:error, reason} -> exit(reason)
        end

      {:stop, ^nonce} ->
        :ok

      {:DOWN, ^executor_monitor, :process, ^executor, _} ->
        :ok

      {:DOWN, ^owner_monitor, :process, ^owner, _} ->
        :ok

      {:DOWN, ^filesystem_monitor, :process, ^filesystem, _} ->
        exit(:filesystem_down)
    after
      Deadline.remaining(deadline) -> exit({:deadline, deadline.kind})
    end
  end

  defp actor_current(executor, owner, filesystem, deadline, lease) do
    with :ok <- Deadline.check(deadline),
         true <- Process.alive?(owner) or {:error, :owner_down},
         true <- Process.alive?(filesystem) or {:error, :filesystem_down},
         true <- Authority.execution_current?(lease, executor) or {:error, :stale_execution},
         do: :ok
  end

  defp stop(runtime) do
    send(runtime.companion, {:stop, runtime.token})

    if Process.alive?(runtime.companion) do
      receive do
        {:DOWN, monitor, :process, companion, _}
        when monitor == runtime.monitor and companion == runtime.companion ->
          :ok
      after
        Deadline.remaining(runtime.context.opts.crawler_deadline) ->
          Process.exit(runtime.companion, :kill)

          receive do
            {:DOWN, monitor, :process, companion, _}
            when monitor == runtime.monitor and companion == runtime.companion ->
              :ok
          end
      end
    end

    Process.demonitor(runtime.monitor, [:flush])
  end
end
