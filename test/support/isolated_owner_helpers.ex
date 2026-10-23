defmodule Crawler.IsolatedOwnerHelpers do
  @moduledoc false

  import ExUnit.Assertions

  alias Crawler.Deadline
  alias Crawler.Export.Runtime
  alias Crawler.Store

  @result_tag "CRAWLER_ISOLATED_OWNER"
  @output_limit 65_536

  def start(parent_root, module, function, source) do
    root =
      Path.join(parent_root, "#{function}-child-" <> Base.encode16(:crypto.strong_rand_bytes(8)))

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    for directory <- ["home", "tmp"], do: File.mkdir!(Path.join(root, directory))
    nonce = Base.encode16(:crypto.strong_rand_bytes(16))
    executable = System.find_executable("elixir")
    assert is_binary(executable)
    paths = Enum.map(:code.get_path(), &Path.expand(List.to_string(&1)))
    assert Enum.all?(paths, &(Path.type(&1) == :absolute))
    erlang_root = List.to_string(:code.root_dir())
    otp = List.to_string(:erlang.system_info(:otp_release))
    ebin = :crawler |> Application.app_dir("ebin") |> Path.expand()
    assert ebin in paths

    modules =
      for module <- [Runtime, Store] do
        assert {:ok, :crawler} = :application.get_application(module)
        path = Path.join(ebin, Atom.to_string(module) <> ".beam")
        assert File.regular?(path)

        assert {:ok, {^module, _chunks}} =
                 :beam_lib.chunks(String.to_charlist(path), [:attributes])

        {Atom.to_string(module), path, file_hash(path)}
      end

    config = %{
      module: Atom.to_string(module),
      function: Atom.to_string(function),
      paths: paths,
      elixir: System.version(),
      erts: List.to_string(:erlang.system_info(:version)),
      otp: otp,
      otp_patch:
        String.trim(File.read!(Path.join([erlang_root, "releases", otp, "OTP_VERSION"]))),
      erlang_root: erlang_root,
      source_hash: file_hash(source),
      modules: modules
    }

    encoded = config |> :erlang.term_to_binary() |> Base.encode64()

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-e", child_script(), "--", encoded, root, source, nonce],
        cd: String.to_charlist(root),
        env: [
          {~c"ERL_FLAGS", ~c"+S 4:4"},
          {~c"HOME", String.to_charlist(Path.join(root, "home"))},
          {~c"TMPDIR", String.to_charlist(Path.join(root, "tmp"))}
        ]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    child = %{port: port, pid: pid, root: root, source: source, nonce: nonce}
    ExUnit.Callbacks.on_exit(fn -> cleanup(child) end)
    child
  end

  defp child_script do
    ~S"""
    [encoded, root, source, nonce] = System.argv()
    config = encoded |> Base.decode64!() |> :erlang.binary_to_term([:safe])
    true = System.version() == config.elixir
    true = List.to_string(:erlang.system_info(:version)) == config.erts
    true = List.to_string(:erlang.system_info(:otp_release)) == config.otp
    true = List.to_string(:code.root_dir()) == config.erlang_root
    true = String.trim(File.read!(Path.join([config.erlang_root, "releases", config.otp, "OTP_VERSION"]))) == config.otp_patch
    true = :erlang.system_info(:schedulers) == 4
    true = :erlang.system_info(:schedulers_online) == 4
    true = Enum.all?(config.paths, &(Path.type(&1) == :absolute))
    true = :code.set_path(Enum.map(config.paths, &String.to_charlist/1))
    true = Enum.map(:code.get_path(), &List.to_string/1) == config.paths
    hash = fn path -> :crypto.hash(:sha256, File.read!(path)) end
    true = hash.(source) == config.source_hash
    for {module, {name, path, expected}} <- Enum.zip([Crawler.Export.Runtime, Crawler.Store], config.modules) do
      true = Atom.to_string(module) == name
      {:module, ^module} = Code.ensure_loaded(module)
      true = List.to_string(:code.which(module)) == path
      true = hash.(path) == expected
    end
    Code.compiler_options(warnings_as_errors: true)
    ExUnit.start(autorun: false, capture_log: true)
    Application.put_env(:logger, :backends, [])
    Application.put_env(:logger, :default_handler, false)
    for app <- [:req, :opq, :plug], do: {:ok, _} = Application.ensure_all_started(app)
    {:ok, tickets} = Crawler.QueueTickets.start_link(Crawler.QueueTickets.application_options())
    {:ok, store} = Crawler.Store.start_link([])
    true = Process.unlink(store)
    {:ok, queues} = DynamicSupervisor.start_link(name: Crawler.QueueSupervisor, strategy: :one_for_one)
    {:ok, css} = Crawler.Parser.CssSheets.start_link([])
    Code.require_file(source)
    fixture_root = Path.join(root, "fixture")
    :ok = File.mkdir(fixture_root)
    :ok = File.chmod(fixture_root, 0o700)
    fixture = %{root: fixture_root, scope: make_ref(), key: make_ref(), observer: self()}
    module = String.to_existing_atom(config.module)
    function = String.to_existing_atom(config.function)
    :ok = apply(module, function, [fixture])
    for pid <- [css, queues, tickets], do: :ok = GenServer.stop(pid)
    true = hash.(source) == config.source_hash
    for {_name, path, expected} <- config.modules, do: true = hash.(path) == expected
    IO.puts("CRAWLER_ISOLATED_OWNER:" <> nonce <> ":ok")
    System.halt(0)
    """
  end

  def await(child, watchdog, buffer \\ "") do
    port = child.port

    receive do
      {^port, {:data, data}} ->
        assert byte_size(buffer) + byte_size(data) <= @output_limit
        await(child, watchdog, buffer <> data)

      {^port, {:exit_status, status}} ->
        assert status == 0, "child exit #{status}: #{buffer}"
        expected = @result_tag <> ":" <> child.nonce <> ":ok"

        results =
          buffer
          |> String.split(~r/\r?\n/)
          |> Enum.filter(&String.starts_with?(&1, @result_tag <> ":"))

        assert results == [expected], "invalid child result: #{buffer}"
        :ok
    after
      Deadline.remaining(watchdog) -> flunk("child exceeded its fixed parent watchdog: #{buffer}")
    end
  end

  def cleanup(child) do
    case child_command(child.pid) do
      {:running, command} ->
        assert String.contains?(command, child.root)
        assert String.contains?(command, child.source)
        assert String.contains?(command, child.nonce)

        {_output, status} =
          System.cmd("kill", ["-KILL", Integer.to_string(child.pid)], stderr_to_stdout: true)

        assert status in [0, 1]
        assert eventually(fn -> child_command(child.pid) == :down end, 100)

      :down ->
        :ok
    end

    if Port.info(child.port) do
      receive do
        {port, {:exit_status, _}} when port == child.port -> :ok
      after
        1000 -> flunk("child exit status was not delivered")
      end

      if Port.info(child.port), do: Port.close(child.port)
    end

    assert {:ok, _} = File.rm_rf(child.root)
    refute File.exists?(child.root)
    :ok
  end

  defp child_command(pid) do
    case System.cmd("ps", ["-ww", "-p", Integer.to_string(pid), "-o", "command="],
           stderr_to_stdout: true
         ) do
      {command, 0} -> {:running, command}
      {_output, 1} -> :down
    end
  end

  defp file_hash(path), do: :crypto.hash(:sha256, File.read!(path))

  defp eventually(callback, 0), do: callback.()

  defp eventually(callback, attempts) do
    if callback.() do
      true
    else
      Process.sleep(10)
      eventually(callback, attempts - 1)
    end
  end
end
