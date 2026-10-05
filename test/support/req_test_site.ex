defmodule Crawler.ReqTestSite do
  @moduledoc false

  defstruct [:agent, :host, :port, :url, :path, :req_options]

  @type t :: %__MODULE__{}

  @handler_timeout 5_000

  alias Crawler.ReqTestSite.Lifecycle

  def open(opts \\ []) do
    host_count = Keyword.get(opts, :hosts, 1)
    handler_timeout = Keyword.get(opts, :handler_timeout, @handler_timeout)
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
          path: "localhost__port_#{port}",
          req_options: [
            plug: {__MODULE__, agent: agent, handler_timeout: handler_timeout},
            retry: false
          ]
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

  def track_crawl(opts, tracking_opts \\ [])

  def track_crawl(%{queue: queue} = opts, tracking_opts) when is_pid(queue) do
    case Keyword.get(opts[:req_options] || [], :plug) do
      {__MODULE__, plug_opts} ->
        agent = Keyword.fetch!(plug_opts, :agent)
        Lifecycle.track_crawl(agent, opts, tracking_opts)

      _ ->
        Lifecycle.cleanup_on_exit(opts)
        :ok
    end
  end

  def track_crawl(_opts, _tracking_opts), do: :ok

  def close(site_or_context) do
    cleanup(site_or_context)
  end

  def verify_on_exit!(site_or_context) do
    ExUnit.Callbacks.on_exit(fn ->
      try do
        verify!(site_or_context)
      after
        cleanup(site_or_context)
      end
    end)

    site_or_context
  end

  def verify!(site_or_context) do
    agent = agent(site_or_context)

    Lifecycle.wait_until_settled(agent)

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

    token = make_ref()

    case route(agent, key, token) do
      {:ok, fun, watcher} ->
        timeout = Keyword.fetch!(opts, :handler_timeout)
        call_route(agent, key, fun, conn, watcher, timeout)

      :error ->
        Plug.Conn.send_resp(conn, 500, "No ReqTestSite route for #{format_key(key)}")

      {:too_many, message} ->
        Plug.Conn.send_resp(conn, 500, message)

      :closed ->
        Plug.Conn.send_resp(conn, 500, "ReqTestSite is closed")
    end
  end

  defp put_route(%__MODULE__{} = site, method, path, type, fun) when is_function(fun, 1) do
    key = {normalize_method(method), site.host, site.port, path}

    Agent.update(site.agent, fn state ->
      put_in(state, [:routes, key], %{type: type, fun: fun, count: 0})
    end)

    site
  end

  defp route(agent, key, token) do
    caller = self()

    Agent.get_and_update(agent, fn state ->
      if state.closing? do
        {:closed, state}
      else
        route(state, key, token, caller, agent)
      end
    end)
  end

  defp route(state, key, token, caller, agent) do
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
        {state, watcher} = Lifecycle.start_request(state, token, caller, agent)

        {{:ok, fun, watcher}, state}
    end
  end

  defp call_route(agent, key, fun, conn, watcher, timeout) do
    callback =
      fn ->
        try do
          {:ok, fun.(conn)}
        catch
          kind, reason ->
            {:error, Exception.format(kind, reason, __STACKTRACE__)}
        end
      end

    try do
      case Lifecycle.handler_result(watcher, callback, timeout) do
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
      Lifecycle.finish_request(watcher)
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
    Map.merge(%{routes: %{}, unexpected: [], failures: []}, Lifecycle.initial_state())
  end

  defp record_failure(agent, message) do
    Agent.update(agent, fn state ->
      update_in(state, [:failures], &[message | &1])
    end)
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

  defp cleanup(site_or_context) do
    agent = agent(site_or_context)

    {pid, ref} =
      spawn_monitor(fn ->
        if Process.alive?(agent) do
          Lifecycle.cleanup(agent)
          Agent.stop(agent)
        end
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
      {:DOWN, ^ref, :process, ^pid, reason} -> exit(reason)
    end
  end
end
