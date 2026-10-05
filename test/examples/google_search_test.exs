defmodule Crawler.Example.GoogleSearchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Crawler.Example.GoogleSearch
  alias Crawler.Example.GoogleSearch.Data
  alias Crawler.Store

  setup do
    scope = make_ref()

    original =
      Enum.map(
        [:scope, :queue, :timeout, :req_options],
        &{&1, Application.fetch_env(:crawler, &1)}
      )

    existing_queues = queue_owners()

    Application.put_env(:crawler, :scope, scope)
    Application.put_env(:crawler, :queue, nil)
    Application.put_env(:crawler, :timeout, :infinity)

    on_exit(fn ->
      Enum.each(queue_owners() -- existing_queues, &Crawler.Queue.stop/1)
      Store.drop_scope(scope)
      if data = Process.whereis(Data), do: Agent.stop(data)

      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:crawler, key, value)
        {key, :error} -> Application.delete_env(:crawler, key)
      end)
    end)

    %{scope: scope, existing_queues: existing_queues}
  end

  test "returns and prints scraped results, then releases owned resources", context do
    parent = self()

    Application.put_env(:crawler, :req_options,
      adapter: fn request ->
        send(parent, {:requested_host, request.url.host})

        body =
          case {request.url.host, request.url.path} do
            {"www.google.com", "/search"} ->
              assert URI.decode_query(request.url.query)["q"] == "github web scrapers in Elixir"

              """
              <a href="https://github.com/fredwu/crawler">crawler</a>
              <a href="https://github.com.evil.test/project">fake GitHub</a>
              <a href="https://www.google.com.evil.test/search">fake Google</a>
              <a href="https://evil.test@github.com/project">credentials</a>
              """

            {"github.com", "/fredwu/crawler"} ->
              """
              <div id="repository-container-header"><strong><a>crawler</a></strong></div>
              <div class="Layout-sidebar"><p class="f4"> A web crawler. </p></div>
              """
          end

        response(request, body)
      end
    )

    expected = %{
      "crawler" => %{url: "https://github.com/fredwu/crawler", desc: "A web crawler."}
    }

    output = capture_io(fn -> assert GoogleSearch.run() == expected end)

    assert output == inspect(expected) <> "\n"
    assert_receive {:requested_host, "www.google.com"}
    assert_receive {:requested_host, "github.com"}
    refute_receive {:requested_host, _host}
    assert_cleaned_up(context)
  end

  test "a crawl startup error propagates and releases the Agent", context do
    Application.put_env(:crawler, :queue, :google_search_unavailable_queue)

    assert_raise MatchError, fn -> GoogleSearch.run() end

    assert_cleaned_up(context)
  end

  test "an output error propagates without retrying and releases owned resources", context do
    {:ok, output} = StringIO.open("")
    gate_request()

    task =
      Task.async(fn ->
        Process.group_leader(self(), output)

        try do
          GoogleSearch.run()
        rescue
          error -> {:error, error}
        end
      end)

    on_exit(fn ->
      Process.exit(task.pid, :kill)
      if Process.alive?(output), do: StringIO.close(output)
    end)

    assert_receive {:request_waiting, handler}, 2_000
    StringIO.close(output)
    send(handler, :release)

    assert {:error, %ErlangError{}} = Task.await(task, 5_000)
    assert_cleaned_up(context)
  end

  test "a crawl that stays active times out and releases its Agent, queue and worker", context do
    gate_request()

    task =
      Task.async(fn ->
        assert_raise RuntimeError, "Google search crawl did not finish within 5 seconds", fn ->
          GoogleSearch.run()
        end
      end)

    on_exit(fn -> Process.exit(task.pid, :kill) end)

    assert_receive {:request_waiting, handler}, 2_000
    on_exit(fn -> send(handler, :release) end)
    data = Process.whereis(Data)
    [owner] = queue_owners() -- context.existing_queues
    monitors = Enum.map([data, owner, handler], &{&1, Process.monitor(&1)})

    Task.await(task, 12_000)

    Enum.each(monitors, fn {pid, ref} ->
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
      refute Process.alive?(pid)
    end)

    assert_cleaned_up(context)
  end

  defp gate_request do
    parent = self()

    Application.put_env(:crawler, :req_options,
      adapter: fn request ->
        send(parent, {:request_waiting, self()})

        receive do
          :release -> response(request, "done")
        end
      end
    )
  end

  defp response(request, body) do
    {request, Req.Response.new(status: 200, headers: [{"content-type", "text/html"}], body: body)}
  end

  defp assert_cleaned_up(context) do
    refute Process.whereis(Data)
    assert queue_owners() == context.existing_queues
    assert Store.pending_count(context.scope) == 0
    assert Store.inflight_count(context.scope) == 0
  end

  defp queue_owners do
    Crawler.QueueSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    |> Enum.sort()
  end
end
