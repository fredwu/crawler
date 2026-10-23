defmodule Crawler.RunStatusTest do
  use Crawler.TestCase, async: false

  alias Crawler.Options
  alias Crawler.Queue
  alias Crawler.QueueHandler
  alias Crawler.Store

  @status_keys Enum.sort([
                 :state,
                 :root_status,
                 :reported_limit,
                 :reason,
                 :running?,
                 :paused?,
                 :terminal?,
                 :pending,
                 :inflight
               ])

  defmodule HeldParser do
    @moduledoc false
    @behaviour Crawler.Parser.Spec

    def parse(%{opts: opts} = page) do
      if URI.parse(page.url).path == opts[:status_hold_path] do
        result = if opts[:status_hold_after], do: Crawler.Parser.parse(page)
        send(opts.status_observer, {:status_parser_held, self()})

        receive do
          :release_status_parser -> result || Crawler.Parser.parse(page)
        end
      else
        Crawler.Parser.parse(page)
      end
    end

    def parse(other), do: Crawler.Parser.parse(other)
  end

  defmodule PrivateFailureParser do
    @moduledoc false
    @behaviour Crawler.Parser.Spec

    def parse(%{opts: opts}), do: {:error, %{private_callback_value: opts.status_secret}}
    def parse(other), do: Crawler.Parser.parse(other)
  end

  defmodule ReportingParser do
    @moduledoc false
    @behaviour Crawler.Parser.Spec

    def parse(%{opts: opts} = page) do
      result = Crawler.Parser.parse(page)
      report = Crawler.Store.report_run_limit({:limit, :max_pending})
      send(opts.status_observer, {:status_claimed_report, report})
      result
    end

    def parse(other), do: Crawler.Parser.parse(other)
  end

  test "ordinary fanout reports its limit before quiescence and preserves root success",
       context do
    html(context, "/status/root", """
    <a href="/status/one">one</a>
    <a href="/status/two">two</a>
    <a href="/status/three">three</a>
    """)

    for path <- ["/status/one", "/status/two", "/status/three"] do
      html(context, path, "child")
    end

    opts =
      crawl(context, "/status/root", %{
        max_pending: 2,
        parser: HeldParser,
        status_observer: self(),
        status_hold_path: "/status/root",
        status_hold_after: true
      })

    worker = held_parser()
    status = status!(opts)
    assert status.state == :running
    assert status.reported_limit == {:limit, :max_pending}
    assert status.reason == {:limit, :max_pending}
    assert status.running?
    refute status.terminal?
    assert status.pending == 2
    assert status.inflight == 1
    frontier = :sys.get_state(Store).scheduler.frontier

    assert [child] =
             frontier.runs[{opts.scope, opts.generation}].jobs
             |> MapSet.delete(opts.target_handle)
             |> MapSet.to_list()

    assert frontier.jobs[child].job.logical_key == context.url <> "/status/one"
    send(worker, :release_status_parser)

    status = terminal_status(opts)
    assert status.state == :limited
    assert status.root_status == :succeeded
    assert status.reported_limit == {:limit, :max_pending}
    assert status.reason == {:limit, :max_pending}
    assert Store.ops_count(opts.scope) == 2
    assert %{status: :succeeded} = Store.target_outcome(child)
    refute status.running?
    assert status.pending == 0
    assert status.inflight == 0
  end

  test "scheduler page limits remain visible after a successful root", context do
    html(
      context,
      "/status/page-limit",
      "<a href='/status/pending-one'>one</a><a href='/status/pending-two'>two</a>"
    )

    opts =
      crawl(context, "/status/page-limit", %{
        max_pages: 1,
        parser: HeldParser,
        status_observer: self(),
        status_hold_path: "/status/page-limit",
        status_hold_after: true
      })

    worker = held_parser()
    frontier = :sys.get_state(Store).scheduler.frontier

    children =
      MapSet.delete(frontier.runs[{opts.scope, opts.generation}].jobs, opts.target_handle)

    assert MapSet.size(children) == 2
    assert status!(opts).reported_limit == nil
    send(worker, :release_status_parser)

    status = terminal_status(opts)
    assert status.state == :limited
    assert status.root_status == :succeeded
    assert status.reported_limit == {:limit, :max_pages}
    assert status.reason == {:limit, :max_pages}
    assert status.pending == 0
    assert status.inflight == 0
    assert Store.ops_count(opts.scope) == 1

    for child <- children do
      assert %{status: :limited, reason: {:limit, :max_pages}} = Store.target_outcome(child)
    end
  end

  test "a paused ordinary queue stays nonterminal and resumes the same root", context do
    html(context, "/status/paused", "root")
    opts = paused_crawl(context, "/status/paused")
    status = status!(opts)
    assert status.state == :paused
    assert status.paused?
    refute status.running?
    refute status.terminal?
    assert status.pending == 1
    assert status.inflight == 0

    Crawler.resume(opts)
    status = terminal_status(opts)
    assert status.state == :succeeded
    assert status.root_status == :succeeded
    refute status.paused?
    refute status.running?
    assert status.reason == nil
    assert status.reported_limit == nil
  end

  test "a claimed parser can report a bounded limit while its root still succeeds", context do
    secret = "private-report-token-#{System.unique_integer([:positive])}"
    html(context, "/status/claimed-report", secret)

    opts =
      crawl(context, "/status/claimed-report", %{
        parser: ReportingParser,
        status_observer: self()
      })

    assert_receive {:status_claimed_report, :ok}, 2_000
    status = terminal_status(opts)
    assert status.state == :limited
    assert status.root_status == :succeeded
    assert status.reported_limit == {:limit, :max_pending}
    assert status.reason == {:limit, :max_pending}
    refute status.running?
    refute status.paused?
    assert status.pending == 0
    assert status.inflight == 0
    assert Store.ops_count(opts.scope) == 1
    assert %{status: :succeeded} = Store.target_outcome(opts.target_handle)
    refute String.contains?(inspect(status), secret)
  end

  test "registered queues can read their shared canonical root without changing queue identity",
       context do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    ReqTestSite.stub(context.site, "GET", "/status/shared", fn conn ->
      Agent.update(calls, &(&1 + 1))

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "shared root")
    end)

    first = paused_crawl(context, "/status/shared")
    second_queue = paused_queue(first)
    supplied = first |> Map.put(:queue, second_queue) |> Map.delete(:queue_owner)
    assert {:ok, second} = start_crawl(first.url, supplied)
    on_exit(fn -> Crawler.stop(second) end)
    refute first.queue == second.queue
    assert second.queue == second_queue
    assert second.generation === first.generation
    assert second.target_handle === first.target_handle

    for opts <- [first, second] do
      status = status!(opts)
      assert status.state == :paused
      assert status.pending == 1
      refute status.terminal?
    end

    state = :sys.get_state(Store)
    refute Map.has_key?(state.scopes[first.scope].work, nil)
    refute Map.has_key?(state.scopes[first.scope].work, self())

    for queue <- [nil, self()] do
      assert Crawler.run_status(%{second | queue: queue}) == {:error, :stale}
    end

    assert Agent.get(calls, & &1) == 0
    Crawler.resume(first)

    for opts <- [first, second] do
      status = terminal_status(opts)
      assert status.state == :succeeded
      assert status.root_status == :succeeded
      assert status.pending == 0
      assert status.inflight == 0
    end

    assert second.queue == second_queue
    refute first.queue == second.queue
    assert {:paused, _, _} = OPQ.info(second.queue)
    assert Agent.get(calls, & &1) == 1
    assert Store.ops_count(first.scope) == 1

    for queue <- [nil, self()] do
      assert Crawler.run_status(%{second | queue: queue}) == {:error, :stale}
    end
  end

  test "root failure exposes a scalar reason without the callback payload", context do
    secret = "private-status-token-#{System.unique_integer([:positive])}"
    html(context, "/status/failure", "root")

    opts =
      crawl(context, "/status/failure", %{
        parser: PrivateFailureParser,
        status_secret: secret
      })

    status = terminal_status(opts)
    assert status.state == :failed
    assert status.root_status == :failed
    assert status.reason == :root_failed
    assert status.reported_limit == nil
    refute String.contains?(inspect(status), secret)
    refute String.contains?(inspect(status), "private_callback_value")
    refute status.running?
  end

  for {kind, timeouts} <- [
        attempt: %{attempt_timeout: 500, run_timeout: 5_000},
        run: %{attempt_timeout: 5_000, run_timeout: 500}
      ] do
    test "an expired #{kind} deadline remains readable after work settles", context do
      path = "/status/deadline-#{unquote(kind)}"
      html(context, path, "root")

      opts =
        crawl(
          context,
          path,
          Map.merge(unquote(Macro.escape(timeouts)), %{
            parser: HeldParser,
            status_observer: self(),
            status_hold_path: path
          })
        )

      worker = held_parser()
      monitor = Process.monitor(worker)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 5_000

      status =
        wait(fn ->
          status = status!(opts)
          assert status.terminal?
          assert status.reported_limit == {:deadline, unquote(kind)}
          status
        end)

      assert status.state == :limited
      assert status.root_status == :limited
      assert status.reason == {:deadline, unquote(kind)}
      refute status.running?
      assert status.pending == 0
      assert status.inflight == 0
      assert Crawler.run_status(Map.to_list(opts)) == {:ok, status}
    end
  end

  test "nil and absent scope queries use the admitted identity and disposal makes both stale",
       context do
    Store.dispose_scope(nil)
    on_exit(fn -> Store.dispose_scope(nil) end)
    html(context, "/status/nil", "root")
    opts = options(context, "/status/nil", %{scope: nil})
    assert {:ok, bound} = QueueHandler.enqueue(opts, :root)
    on_exit(fn -> Crawler.stop(bound) end)
    assert bound.scope == nil
    status = terminal_status(bound)
    assert status.state == :succeeded
    absent = Map.delete(bound, :scope)
    assert Crawler.run_status(absent) == {:ok, status}
    assert :ok = Store.dispose_scope(nil, bound.generation)
    assert Crawler.run_status(bound) == {:error, :stale}
    assert Crawler.run_status(absent) == {:error, :stale}
  end

  test "foreign roots queues and generation tokens cannot read another run", context do
    html(context, "/status/authority", "root")
    first = paused_crawl(context, "/status/authority")
    second = paused_crawl(context, "/status/authority")
    before = status!(first)

    for forged <- [
          %{first | target_handle: second.target_handle},
          %{first | queue: second.queue},
          %{first | generation: second.generation},
          %{first | scope: second.scope},
          Map.delete(first, :target_handle),
          Map.delete(first, :generation)
        ] do
      assert Crawler.run_status(forged) == {:error, :stale}
    end

    assert status!(first) == before
    refute status!(second).terminal?
  end

  test "a replacement rejects old status and unowned reports cannot change the new run",
       context do
    html(context, "/status/replacement", "root")
    old = paused_crawl(context, "/status/replacement")
    assert {:ok, replacement} = Crawler.crawl(old.url, Map.put(old, :force, true))
    on_exit(fn -> Crawler.stop(replacement) end)
    refute replacement.generation === old.generation
    assert Crawler.run_status(old) == {:error, :stale}
    before = status!(replacement)

    for reason <- [
          {:limit, :max_pending},
          {:limit, {:analysis, :bytes}},
          {:deadline, :attempt},
          {:deadline, :run}
        ] do
      assert Store.report_run_limit(reason) == {:error, :stale}
      assert status!(replacement) == before
    end

    assert :ok = Crawler.stop(replacement)
    assert Crawler.run_status(replacement) == {:error, :stale}
  end

  for mode <- [:force, :scope], expired? <- [false, true] do
    test "explicit #{mode} startup has a fresh deadline after expired=#{expired?}", context do
      mode = unquote(mode)
      expired? = unquote(expired?)
      html(context, "/status/new-run", "new root")
      supplied = options(context, "/status/new-run", %{run_timeout: 1_000})
      queue = paused_queue(supplied)

      old =
        crawl(context, "/status/new-run", %{
          scope: supplied.scope,
          queue: queue,
          run_timeout: 1_000
        })

      assert {:ok, duplicate} = Crawler.crawl_reference(old.url, old)
      assert duplicate.generation === old.generation
      assert duplicate.target_handle === old.target_handle
      assert duplicate.run_deadline === old.run_deadline

      if expired? do
        wait(fn -> assert Crawler.Deadline.remaining(old.run_deadline) == 0 end)
        assert {:error, {:deadline, :run}} = Crawler.crawl_reference(old.url, old)
      end

      options = Map.put(old, :run_timeout, 5_000)

      options =
        case mode do
          :force -> Map.put(options, :force, true)
          :scope -> Map.put(options, :scope, unique_scope("new-deadline"))
        end

      assert {:ok, fresh} = start_crawl(old.url, options)
      on_exit(fn -> Crawler.stop(fresh) end)
      assert fresh.queue === queue
      refute fresh.generation === old.generation
      assert fresh.run_deadline.at > old.run_deadline.at
      assert :ok = Crawler.Deadline.check(fresh.run_deadline)
      assert Process.alive?(queue)
      Crawler.resume(fresh)
      status = terminal_status(fresh)
      assert status.state == :succeeded
      assert status.root_status == :succeeded
      assert status.reported_limit == nil
      assert Store.ops_count(fresh.scope) == 1
      assert Process.alive?(queue)
    end
  end

  defp status!(opts) do
    assert {:ok, status} = Crawler.run_status(opts)
    assert Enum.sort(Map.keys(status)) == @status_keys
    status
  end

  defp terminal_status(opts) do
    wait(fn ->
      status = status!(opts)
      assert status.terminal?
      status
    end)
  end

  defp held_parser do
    assert_receive {:status_parser_held, worker}, 2_000
    on_exit(fn -> send(worker, :release_status_parser) end)
    worker
  end

  defp crawl(context, path, extra) do
    opts = options(context, path, extra)
    assert {:ok, bound} = start_crawl(opts.url, opts)
    on_exit(fn -> Crawler.stop(bound) end)
    bound
  end

  defp paused_crawl(context, path) do
    opts = options(context, path, %{})
    queue = paused_queue(opts)
    crawl(context, path, %{scope: opts.scope, queue: queue})
  end

  defp paused_queue(opts) do
    owner = start_supervised!(Supervisor.child_spec({Queue, opts}, id: make_ref()))
    queue = Queue.feeder(owner)
    OPQ.pause(queue)
    assert {:paused, _, _} = OPQ.info(queue)
    queue
  end

  defp options(context, path, extra) do
    Map.merge(
      %{
        url: context.url <> path,
        scope: unique_scope("run-status"),
        workers: 1,
        interval: 0,
        retries: 0,
        timeout: 5_000,
        attempt_timeout: 5_000,
        run_timeout: 10_000,
        respect_robots: false,
        save_to: nil,
        store: nil,
        max_body: 262_144,
        max_analysis_bytes: 2_000_000,
        req_options: context.req_options
      },
      extra
    )
    |> Options.assign_defaults()
  end

  defp html(context, path, body) do
    ReqTestSite.stub(context.site, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, body)
    end)
  end
end
