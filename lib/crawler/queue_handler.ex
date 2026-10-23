defmodule Crawler.QueueHandler do
  @moduledoc """
  Handles the queueing of crawl requests.
  """

  alias Crawler.Queue
  alias Crawler.Store

  @doc """
  Enqueues a crawl request.

  Also initialises the queue if it's not already initialised, this is necessary
  so that consumer apps don't have to manually handle the queue initialisation.

  An unavailable named queue returns `{:error, {:queue_unavailable, name}}`.
  """
  def enqueue(opts, ingress \\ :reference), do: enqueue_job(opts, :fetch, ingress)

  @doc false
  def enqueue_control(url, opts) do
    opts = opts |> Map.new() |> Crawler.Options.assign_defaults() |> Map.put(:url, url)
    enqueue_job(opts, :sitemap, :reference)
  end

  defp enqueue_job(opts, kind, ingress) do
    opts =
      Map.drop(opts, [
        :execution_lease,
        :crawler_ingress,
        :crawler_deadline,
        :scheduler_claim,
        :scheduler_mode,
        :scheduler_kind,
        :prepared_request,
        :target_handle,
        :representation_id,
        :cookie_proof,
        :analysis,
        :interpretation,
        :source_revision,
        :source_entity_bytes,
        :body_resource,
        :page_resource,
        :css_obligation_receipt,
        :return_reservation,
        :return_workspace,
        :queue_admission_caller
      ])

    opts = Map.put(opts, :discovery_mode, :parse)

    opts =
      if opts[:force] == true and opts[:depth] == 0,
        do: Map.delete(opts, :run_deadline),
        else: opts

    with {:ok, opts, started?} <- init_queue(opts[:queue], opts) do
      opts = if started?, do: opts, else: assign_queue_owner(opts)

      try do
        result = admit(opts, kind, ingress)
        finish_startup(opts, started?, result)
        result
      catch
        caught, reason ->
          if started?, do: Queue.stop(opts[:queue_owner])
          :erlang.raise(caught, reason, __STACKTRACE__)
      end
    end
  end

  defp finish_startup(opts, true, {:ok, _}), do: :ok = Queue.admission_handoff(opts.queue_owner)
  defp finish_startup(opts, true, _result), do: Queue.stop(opts.queue_owner)
  defp finish_startup(_opts, false, _result), do: :ok

  defp admit(opts, kind, ingress) do
    with true <- queue_alive?(opts[:queue]),
         :ok <-
           Crawler.QueueTickets.attach(
             opts.queue,
             opts.max_queue_tickets,
             Crawler.QueueTickets,
             opts.max_tracked_queues
           ) do
      Crawler.Store.Execution.admit(opts, kind, ingress)
    else
      false -> {:error, {:queue_unavailable, opts[:queue]}}
      error -> error
    end
  end

  defp queue_alive?(queue) when is_pid(queue), do: Process.alive?(queue)

  defp queue_alive?(_queue), do: false

  defp assign_queue_owner(%{queue: queue} = opts) when is_pid(queue) do
    scope = opts[:scope]

    case Store.queue_record(queue) do
      %{owner: owner, scope: ^scope} when is_pid(owner) -> Map.put(opts, :queue_owner, owner)
      _ -> Map.delete(opts, :queue_owner)
    end
  end

  defp assign_queue_owner(opts), do: Map.delete(opts, :queue_owner)

  defp init_queue(nil, opts) do
    spec =
      Supervisor.child_spec(
        {Queue, Map.put(opts, :queue_admission_caller, self())},
        shutdown: 10_000,
        restart: :temporary
      )

    {:ok, owner} = DynamicSupervisor.start_child(Crawler.QueueSupervisor, spec)
    feeder = Queue.feeder(owner)

    opts =
      opts
      |> Map.put(:queue, feeder)
      |> Map.put(:queue_owner, owner)
      |> Map.delete(:queue_name)

    {:ok, opts, true}
  end

  defp init_queue(queue, opts) when is_atom(queue) do
    case Process.whereis(queue) do
      nil ->
        {:error, {:queue_unavailable, queue}}

      pid ->
        {:ok, opts |> Map.put(:queue, pid) |> Map.put(:queue_name, queue), false}
    end
  end

  defp init_queue(queue, %{queue_name: name} = opts) when is_pid(queue) and is_atom(name) do
    opts = if Process.whereis(name) == queue, do: opts, else: Map.delete(opts, :queue_name)
    {:ok, opts, false}
  end

  defp init_queue(_queue, opts), do: {:ok, Map.delete(opts, :queue_name), false}
end
