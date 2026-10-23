defmodule Crawler.SettlementClaimHelpers do
  @moduledoc false

  import ExUnit.Assertions
  alias Crawler.Store
  alias Crawler.Store.Execution
  alias Crawler.Store.Page

  def start_source(context, opts, landing, body \\ "FALLBACK") do
    Crawler.ReqTestSite.expect_once(context.site, "GET", URI.parse(opts.url).path, fn conn ->
      conn |> Plug.Conn.put_resp_header("location", landing) |> Plug.Conn.resp(302, "")
    end)

    Crawler.ReqTestSite.expect_once(context.site, "GET", URI.parse(landing).path, fn conn ->
      conn |> Plug.Conn.put_resp_header("content-type", "text/plain") |> Plug.Conn.resp(200, body)
    end)

    opts =
      Map.merge(opts, %{
        req_options: context.req_options,
        respect_robots: false,
        retries: 0,
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000
      })

    parent = self()
    supervisor = ExUnit.Callbacks.start_supervised!(Task.Supervisor)
    queued = if opts.queue, do: enqueue(opts), else: opts
    task = Task.Supervisor.async_nolink(supervisor, fn -> run_source(queued, parent) end)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)
    end)

    receive do
      {:retained_source, executor, ref, owned} ->
        %{task: task, executor: executor, ref: ref, opts: owned}
    after
      2_000 ->
        flunk(
          "canonical source did not retain its redirect fallback: #{inspect(Task.yield(task, 0))}"
        )
    end
  end

  def finish_source(source) do
    send(source.executor, :finish_source)
    assert :ok = Task.await(source.task, 2_000)
  end

  defp enqueue(opts) do
    assert {:ok, queued} = Crawler.crawl(opts.url, opts)
    queued
  end

  defp run_source(%{queue: nil} = opts, parent),
    do: Execution.run_job(opts, &fetch_source(&1, parent))

  defp run_source(opts, parent) do
    assert {:ok, claim, :fetch, admitted} = Store.checkout_job(opts.queue)
    result = Execution.run(admitted, &fetch_source(&1, parent))
    Store.complete_job(claim, Crawler.Job.Outcome.from_result(result))
    result
  end

  defp fetch_source(owned, parent) do
    assert %Page{} = page = Crawler.Fetcher.fetch(owned)
    opts = Map.take(page.opts, [:url, :scope, :generation, :queue])
    send(parent, {:retained_source, self(), page.opts[:alias_candidate], opts})

    receive do
      :finish_source ->
        :ok = Store.complete_page({page.url, opts.scope}, opts.generation, opts.queue, nil, false)
        :ok
    end
  end
end
