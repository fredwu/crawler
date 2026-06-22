defmodule Crawler.ReqTestSite do
  @moduledoc false

  defstruct [:agent, :host, :port, :url, :path, :req_options]

  @type t :: %__MODULE__{}

  @settle_timeout 5_000
  @quiet_window 50

  def open(opts \\ []) do
    host_count = Keyword.get(opts, :hosts, 1)
    {:ok, agent} = Agent.start(fn -> initial_state() end)

    sites =
      for index <- 0..(host_count - 1) do
        port = fake_port(index, host_count)
        url = "http://localhost:#{port}"

        %__MODULE__{
          agent: agent,
          host: "localhost",
          port: port,
          url: url,
          path: "localhost-#{port}",
          req_options: [plug: {__MODULE__, agent: agent}, retry: false]
        }
      end

    context = context(sites)

    if Keyword.get(opts, :verify_on_exit, true) do
      verify_on_exit!(context)
    else
      context
    end
  end

  def expect_once(site, method, path, fun) do
    put_route(site, method, path, :once, fun)
  end

  def expect(site, method, path, fun) do
    put_route(site, method, path, :expect, fun)
  end

  def stub(site, method, path, fun) do
    put_route(site, method, path, :stub, fun)
  end

  def req_options(%__MODULE__{req_options: req_options}), do: req_options
  def req_options(%{site: site}), do: req_options(site)

  def close(site_or_context) do
    stop_agent(site_or_context)
  end

  def verify_on_exit!(site_or_context) do
    ExUnit.Callbacks.on_exit(fn ->
      try do
        verify!(site_or_context)
      after
        stop_agent(site_or_context)
      end
    end)

    site_or_context
  end

  def verify!(site_or_context) do
    agent = agent(site_or_context)

    wait_until_settled(agent)

    %{routes: routes, unexpected: unexpected, failures: failures} = Agent.get(agent, & &1)

    failures =
      routes
      |> Enum.flat_map(fn {key, route} -> route_failures(key, route) end)
      |> Kernel.++(unexpected_failures(unexpected))
      |> Kernel.++(Enum.reverse(failures))

    if failures != [] do
      raise ExUnit.AssertionError, message: Enum.join(failures, "\n")
    end

    :ok
  end

  def init(opts), do: opts

  def call(conn, opts) do
    agent = Keyword.fetch!(opts, :agent)
    key = {conn.method, conn.host, conn.port, conn.request_path}

    case route(agent, key) do
      {:ok, fun} ->
        call_route(agent, key, fun, conn)

      :error ->
        Plug.Conn.send_resp(conn, 500, "No ReqTestSite route for #{format_key(key)}")

      {:too_many, message} ->
        Plug.Conn.send_resp(conn, 500, message)
    end
  end

  defp put_route(%__MODULE__{} = site, method, path, type, fun) when is_function(fun, 1) do
    key = {normalize_method(method), site.host, site.port, path}

    Agent.update(site.agent, fn state ->
      put_in(state, [:routes, key], %{type: type, fun: fun, count: 0})
    end)

    site
  end

  defp route(agent, key) do
    Agent.get_and_update(agent, fn state ->
      state = update_in(state, [:requests], &(&1 + 1))

      case get_in(state, [:routes, key]) do
        nil ->
          state = update_in(state, [:unexpected], &[key | &1])

          {:error, state}

        %{type: :once, count: count} when count >= 1 ->
          message = "Expected #{format_key(key)} exactly once, got an extra request"
          state = update_in(state, [:failures], &[message | &1])

          {{:too_many, message}, state}

        route ->
          fun = route.fun
          state = put_in(state, [:routes, key, :count], route.count + 1)
          state = update_in(state, [:active], &(&1 + 1))

          {{:ok, fun}, state}
      end
    end)
  end

  defp call_route(agent, key, fun, conn) do
    task =
      Task.async(fn ->
        try do
          {:ok, fun.(conn)}
        catch
          kind, reason ->
            {:error, Exception.format(kind, reason, __STACKTRACE__)}
        end
      end)

    try do
      case Task.await(task) do
        {:ok, conn} ->
          conn

        {:error, message} ->
          record_failure(agent, "Handler for #{format_key(key)} failed:\n#{message}")
          Plug.Conn.send_resp(conn, 500, "ReqTestSite handler failed for #{format_key(key)}")
      end
    catch
      :exit, reason ->
        record_failure(agent, "Handler for #{format_key(key)} exited: #{inspect(reason)}")
        Plug.Conn.send_resp(conn, 500, "ReqTestSite handler failed for #{format_key(key)}")
    after
      finish_route(agent)
    end
  end

  defp route_failures(_key, %{type: :once, count: 1}), do: []

  defp route_failures(key, %{type: :once, count: count}) do
    ["Expected #{format_key(key)} exactly once, got #{count} calls"]
  end

  defp route_failures(_key, %{type: :expect, count: count}) when count >= 1, do: []

  defp route_failures(key, %{type: :expect, count: count}) do
    ["Expected #{format_key(key)} at least once, got #{count} calls"]
  end

  defp route_failures(_key, %{type: :stub}), do: []

  defp unexpected_failures(unexpected) do
    Enum.map(unexpected, &"Unexpected request to #{format_key(&1)}")
  end

  defp initial_state do
    %{routes: %{}, unexpected: [], failures: [], active: 0, requests: 0, waiters: []}
  end

  defp record_failure(agent, message) do
    Agent.update(agent, fn state ->
      update_in(state, [:failures], &[message | &1])
    end)
  end

  defp finish_route(agent) do
    Agent.update(agent, fn state ->
      active = max(state.active - 1, 0)
      state = %{state | active: active}

      if active == 0 do
        Enum.each(state.waiters, fn {pid, ref} ->
          send(pid, {:req_test_site_idle, ref})
        end)

        %{state | waiters: []}
      else
        state
      end
    end)
  end

  defp wait_until_settled(agent) do
    wait_until_settled(agent, deadline())
  end

  defp wait_until_settled(agent, deadline) do
    wait_for_crawler_queues(deadline)
    wait_until_idle(agent, deadline)

    requests = request_count(agent)

    wait_for_quiet_window(deadline)
    wait_for_crawler_queues(deadline)
    wait_until_idle(agent, deadline)

    if request_count(agent) == requests do
      :ok
    else
      wait_until_settled(agent, deadline)
    end
  end

  defp wait_until_idle(agent, deadline) do
    ref = make_ref()

    case register_idle_waiter(agent, ref) do
      :idle ->
        :ok

      :waiting ->
        receive do
          {:req_test_site_idle, ^ref} ->
            :ok
        after
          remaining_timeout(deadline) ->
            raise ExUnit.AssertionError,
              message: "Timed out waiting for ReqTestSite requests to finish"
        end
    end
  end

  defp register_idle_waiter(agent, ref) do
    caller = self()

    Agent.get_and_update(agent, fn state ->
      if state.active == 0 do
        {:idle, state}
      else
        {:waiting, update_in(state, [:waiters], &[{caller, ref} | &1])}
      end
    end)
  end

  defp request_count(agent) do
    Agent.get(agent, & &1.requests)
  end

  defp wait_for_quiet_window(deadline) do
    wait_for_timeout(@quiet_window, deadline)
  end

  defp wait_for_crawler_queues(deadline) do
    if crawler_queues_idle?() do
      :ok
    else
      wait_for_timeout(10, deadline)
      wait_for_crawler_queues(deadline)
    end
  end

  defp crawler_queues_idle? do
    case Process.whereis(Crawler.QueueSupervisor) do
      nil ->
        true

      supervisor ->
        supervisor
        |> DynamicSupervisor.which_children()
        |> Enum.all?(fn
          {_, pid, :worker, _} when is_pid(pid) -> queue_idle?(pid)
          _ -> true
        end)
    end
  catch
    :exit, _ -> true
  end

  defp queue_idle?(pid) do
    !Process.alive?(pid) || queue_empty?(OPQ.info(pid))
  catch
    :exit, _ -> true
  end

  defp queue_empty?({_status, %OPQ.Queue{data: data}, _demand}) do
    :queue.is_empty(data)
  end

  defp deadline do
    System.monotonic_time(:millisecond) + @settle_timeout
  end

  defp wait_for_timeout(timeout, deadline) do
    timeout = min(timeout, remaining_timeout(deadline))

    if timeout <= 0 do
      raise ExUnit.AssertionError,
        message: "Timed out waiting for ReqTestSite requests to settle"
    end

    receive do
    after
      timeout -> :ok
    end
  end

  defp remaining_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp context([site]),
    do: %{site: site, url: site.url, path: site.path, req_options: req_options(site)}

  defp context([site, site2 | _] = sites) do
    %{
      sites: sites,
      site: site,
      site2: site2,
      url: site.url,
      url2: site2.url,
      path: site.path,
      path2: site2.path,
      req_options: req_options(site)
    }
  end

  defp fake_port(index, host_count) do
    offset = System.unique_integer([:positive, :monotonic]) * max(host_count, 1) + index

    40_000 + rem(offset, 20_000)
  end

  defp normalize_method(method) do
    method
    |> to_string()
    |> String.upcase()
  end

  defp format_key({method, host, port, path}) do
    "#{method} http://#{host}:#{port}#{path}"
  end

  defp agent(%__MODULE__{agent: agent}), do: agent
  defp agent(%{site: site}), do: agent(site)

  defp stop_agent(site_or_context) do
    agent = agent(site_or_context)

    if Process.alive?(agent) do
      Agent.stop(agent)
    end
  end
end
