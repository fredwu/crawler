defmodule Crawler.Export.Filesystem do
  @moduledoc """
  Bounded, exclusive filesystem staging under an isolated directory.

  The caller supplies an existing, user-owned root directory without group/other
  write access. Read access, such as mode 0755, is allowed. Every ancestor must
  be a real directory owned by the current user or root. Shared writable ancestors
  require the sticky bit. The caller must ensure no ACL grants extra write access
  to parents or inherited access to private stage and claim directories.
  This isolated-ownership policy excludes hostile concurrent local modification;
  pathname checks do not provide directory-handle or no-follow guarantees.

  `acquire/3` claims a fresh managed destination across OS VMs. Keep the returned
  receipt privately for `recover/1` after the entire owning VM has stopped.
  Recovery is an explicit capability operation, never a PID/age-based takeover.
  It only cleans up; it cannot resume writing. Unknown, incomplete, or changed
  ownership records fail closed and can require manual inspection.

  `reserve/4` reserves bytes and a file slot before a producer materializes data.
  `write/3` consumes that reservation exactly once. `write/4` combines these two
  steps for an existing binary. Original sources, metadata, and archive files all
  count against the disk budget. Reservations are not filesystem preallocation;
  IO failures (including ENOSPC) remain explicit errors. Journal bytes have their
  own fixed bound. A failed write poisons publication until the owner aborts.

  `prepare/1` seals reservations and writes, validates paths, and journals rename
  intent in the filesystem worker. Run preparation outside Store. The returned
  opaque immutable handle captures the selected owner, paths, identities, and a
  single-use atomic gate. `:owner` defaults to the acquiring process. IO workers
  may call `abort/1` to abandon staging; only the selected owner may promote or
  cancel a prepared handle. These handles are capabilities within a trusted VM.
  `prepared_for?/2` checks the exact recovery receipt and an unused sealed gate
  locally in that owner, without IO or changing the gate. It does not validate
  current paths; promotion still performs the fixed final path checks.

  `promote/1` executes in that selected owner, with no filesystem-worker call.
  Its fixed raw identity checks and direct OTP `:prim_file.rename/2` do not queue
  work in the file server. Store must call it inside the authoritative commit
  callback that checks revocation and transitions to ready. `cancel/1` locally
  closes a prepared handle without IO; an IO worker calls `finish/1` afterward.
  No process other than the selected owner can use a prepared handle, including
  after owner death. An OS rename syscall already issued cannot be cancelled.
  Owner death during that syscall leaves bounded recovery state instead of racing
  cleanup against the syscall. Recovery after VM termination resolves placement;
  a `:promoted` recovery result never establishes Store readiness.

  Completed managed claims remain outside the archive and prevent both managed
  overwrite and standalone intrusion, including nested roots. The private claim
  registry uses native filesystem names so aliases on case-insensitive and
  Unicode-normalizing filesystems contend on the same directory entry. The empty
  registry stays in place to avoid races removing a registry used by another VM.

  `acquire_file/3` supports retaining a standalone receipt before publication.
  `publish_file/4` uses the same claim, exclusive staging, budgets, and cleanup for
  atomic standalone file replacement. It returns a per-file result, never archive
  readiness. Caller-supplied artifact paths must already exclude credentials;
  generated staging and recovery IDs are random. This module accepts no URL identity.

  The guarantees cover process/VM failure, not power-loss durability. Cleanup
  never recursively scans a root: it reads at most the bounded journal and visits
  recorded entries. A crash before an entry is journaled can leave a private
  orphan; the claim stays locked rather than deleting an unidentified file.
  """

  use GenServer
  import Bitwise

  @prefix ".crawler-fs-"
  @defaults %{
    max_bytes: 256 * 1024 * 1024,
    max_file_bytes: 32 * 1024 * 1024,
    max_metadata_bytes: 1024 * 1024,
    max_files: 10_000,
    max_entries: 40_000,
    max_journal_bytes: 8 * 1024 * 1024
  }
  @areas [:archive, :source, :metadata]
  @registry ".crawler-fs-claims"
  @registry_marker ".crawler-fs-owner"
  @registry_header "crawler-filesystem-v1:"
  @prepared_tag :crawler_filesystem_prepared
  @sealed 1
  @committing 2
  @promoted 3
  @cancelled 4
  @failed 5
  @opaque prepared ::
            {:crawler_filesystem_prepared,
             (:promote | :cancel | {:identity, term()} -> :ok | {:error, term()} | boolean())}
  # Only the dedicated staging process appends. Recovery never resumes journal writes.
  @journal_count {__MODULE__, :journal_entries}

  @doc "Claims a fresh destination below an isolated parent root. Returns an owner and recovery receipt."
  def acquire(root, destination, opts \\ []) do
    start(root, destination, :managed, nil, opts)
  end

  @doc """
  Spawns one dormant managed-filesystem actor, monitored by the calling owner.

  Record its PID, monitor, and nonce before sending
  `{:crawler_filesystem_activate, nonce, self()}`. No filesystem IO occurs before
  that activation. The actor reports its actual setup result directly to the owner
  as `{:crawler_filesystem_acquired, nonce, actor_pid, result}`. On success, the
  same actor serves the existing filesystem API. Other owners are refused.

  Owner death before activation stops the dormant actor without IO. Owner death
  during setup cannot interrupt an IO operation already issued. On retirement,
  retain actor custody until verified DOWN; partial unknown claims remain fail closed.
  No deadline option is accepted; the owner controls activation and retirement.
  """
  @spec spawn_acquisition(binary(), binary(), reference(), keyword()) ::
          {:ok, pid(), reference()} | {:error, term()}
  def spawn_acquisition(root, destination, nonce, opts \\ []) do
    with true <- is_reference(nonce) or {:error, :invalid_nonce},
         :ok <- name(destination),
         {:ok, owner, limits} <- options(opts),
         true <- owner == self() or {:error, :not_owner} do
      {pid, monitor} =
        :proc_lib.spawn_opt(
          fn -> acquisition(owner, root, destination, nonce, limits) end,
          [:monitor]
        )

      {:ok, pid, monitor}
    end
  end

  @doc "Claims one standalone file before staging, so its recovery receipt can be retained."
  def acquire_file(root, path, opts \\ []) do
    with :ok <- relative(path) do
      start(root, hd(Path.split(path)), :standalone, path, opts)
    end
  end

  @doc "Reserves a file path and its maximum byte count before producing its contents."
  def reserve(owner, area, path, bytes), do: call(owner, {:reserve, area, path, bytes})

  @doc "Writes one binary to its reserved exclusive file."
  def write(owner, ticket, bytes), do: call(owner, {:write, ticket, bytes})

  @doc "Reserves and writes one binary in the archive, source, or metadata area."
  def write(owner, area, path, bytes) when is_binary(bytes) do
    call(owner, {:write_new, area, path, bytes})
  end

  @doc "Seals and validates staging outside the commit owner. No writes are accepted afterward."
  @spec prepare(pid()) :: {:ok, prepared()} | {:error, term()}
  def prepare(filesystem), do: call(filesystem, :prepare)

  @doc """
  Checks whether a sealed, unused handle belongs to this owner and exact recovery receipt.

  Returns false for a closed handle or another owner or receipt. This local query
  does no IO, makes no actor request, and does not change the gate. It does not
  authenticate arbitrary caller-built functions within the trusted VM.
  """
  @spec prepared_for?(term(), term()) :: boolean()
  def prepared_for?({@prepared_tag, operation}, recovery_receipt)
      when is_function(operation, 1) do
    operation.({:identity, recovery_receipt}) === true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def prepared_for?(_, _), do: false

  @doc "Executes only the fixed final checks and rename locally in the selected owner."
  @spec promote(prepared()) :: :ok | {:error, term()}
  def promote({@prepared_tag, operation}) when is_function(operation, 1), do: operation.(:promote)

  @doc "Closes a prepared handle locally in the selected owner, without filesystem IO."
  @spec cancel(prepared()) :: :ok | {:error, term()}
  def cancel({@prepared_tag, operation}) when is_function(operation, 1), do: operation.(:cancel)

  @doc "Cleans a terminal preparation in an IO worker. Never waits on this from Store's commit callback."
  def finish(filesystem), do: call(filesystem, :finish)

  @doc "Cancels and cleans staging in an IO worker. Never removes a promoted destination."
  def abort(filesystem), do: call(filesystem, :abort)

  @doc false
  def terminate_owned(filesystem, operation, nonce)
      when is_pid(filesystem) and operation in [:finish, :abort] and is_reference(nonce) do
    send(filesystem, {:crawler_filesystem_terminate, self(), nonce, operation})
    :ok
  end

  @doc "Cleans a stopped VM's staging using its exact private recovery receipt."
  def recover(
        %{
          root: _,
          root_id: _,
          destination: _,
          mode: _,
          id: _,
          claim: _,
          claim_id: _,
          stage: _,
          stage_id: _,
          header: _,
          header_id: _,
          journal_id: _,
          limits: %{max_entries: _, max_journal_bytes: _}
        } = receipt
      ) do
    with :ok <- validate_receipt(receipt),
         {:ok, entries} <- read_journal(receipt) do
      cleanup(receipt, entries)
    end
  end

  def recover(_), do: {:error, :invalid_receipt}

  @doc "Atomically publishes one standalone file, refusing any managed destination."
  def publish_file(root, path, bytes, opts \\ []) when is_binary(bytes) do
    with {:ok, selected_owner, _} <- options(opts),
         true <- selected_owner == self() or {:error, :not_owner},
         {:ok, owner, receipt} <- acquire_file(root, path, opts) do
      result =
        with :ok <- write(owner, :archive, path, bytes),
             {:ok, prepared} <- prepare(owner),
             :ok <- promote(prepared) do
          :ok
        end

      case abort(owner) do
        {:ok, _} -> result
        {:error, reason} -> {:error, {:cleanup, reason, receipt}}
      end
    end
  end

  defp start(root, destination, mode, file_path, opts) do
    with :ok <- name(destination),
         {:ok, owner, limits} <- options(opts) do
      case GenServer.start(__MODULE__, {owner, root, destination, mode, file_path, limits}) do
        {:ok, pid} -> {:ok, pid, call(pid, :receipt)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp call(owner, message), do: GenServer.call(owner, message, :infinity)

  @impl true
  def init({owner, root, destination, mode, file_path, limits}) do
    with {:ok, receipt} <- setup(root, destination, mode, file_path, limits) do
      {:ok, initial_state(owner, Process.monitor(owner), receipt)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp initial_state(owner, monitor, receipt) do
    %{
      owner: owner,
      monitor: monitor,
      receipt: receipt,
      tickets: %{},
      paths: MapSet.new(),
      bytes: 0,
      metadata_bytes: 0,
      files: 0,
      poisoned: false,
      gate: :atomics.new(1, []),
      sealed: false
    }
  end

  defp acquisition(owner, root, destination, nonce, limits) do
    [_parent | ancestors] = Process.get(:"$ancestors")
    # enter_loop must retain this owner PID if its registered name is replaced.
    Process.put(:"$ancestors", [owner | ancestors])
    monitor = Process.monitor(owner)
    await_activation(owner, monitor, root, destination, nonce, limits)
  end

  defp await_activation(owner, monitor, root, destination, nonce, limits) do
    receive do
      {:crawler_filesystem_activate, ^nonce, ^owner} ->
        if Process.alive?(owner) do
          case setup_classified(root, destination, :managed, nil, limits) do
            {:ok, receipt} ->
              state = initial_state(owner, monitor, receipt)
              send(owner, {:crawler_filesystem_acquired, nonce, self(), {:ok, receipt}})
              :gen_server.enter_loop(__MODULE__, [], state)

            {:error, ownership, reason} ->
              send(
                owner,
                {:crawler_filesystem_acquired, nonce, self(), {:error, ownership, reason}}
              )
          end
        end

      {:crawler_filesystem_activate, _, _} ->
        await_activation(owner, monitor, root, destination, nonce, limits)

      {:DOWN, ^monitor, :process, ^owner, _} ->
        :ok
    end
  end

  @impl true
  def handle_call(:receipt, _from, state), do: {:reply, state.receipt, state}

  def handle_call({:reserve, area, path, bytes}, _from, state) do
    {reply, state} = reservation(state, area, path, bytes)
    {:reply, reply, state}
  end

  def handle_call({:write, ticket, bytes}, _from, state) do
    {reply, state} = write_reserved(state, ticket, bytes)
    {:reply, reply, state}
  end

  def handle_call({:write_new, area, path, bytes}, _from, state) do
    case reservation(state, area, path, byte_size(bytes)) do
      {{:ok, ticket}, state} ->
        {reply, state} = write_reserved(state, ticket, bytes)
        {:reply, reply, state}

      {error, state} ->
        {:reply, error, state}
    end
  end

  def handle_call(:prepare, _from, state) do
    result =
      with :ok <- writable(state),
           true <- map_size(state.tickets) == 0 or {:error, :pending_reservations},
           :ok <- validate_receipt(state.receipt),
           {:ok, _entries} <- read_journal(state.receipt),
           {:ok, paths} <- prepare_destination(state.receipt),
           true <- Process.alive?(state.owner) or {:error, :owner_down} do
        :atomics.put(state.gate, 1, @sealed)
        {:ok, prepared(state, paths)}
      end

    if match?({:ok, _}, result) do
      {:reply, result, %{state | sealed: true}}
    else
      if not state.sealed, do: :atomics.put(state.gate, 1, @failed)
      {:reply, result, %{state | poisoned: true}}
    end
  end

  def handle_call(:abort, _from, state) do
    with :ok <- close_gate(state.gate) do
      {:stop, :normal, recover(state.receipt), state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(:finish, _from, state) do
    if :atomics.get(state.gate, 1) in [@promoted, @cancelled, @failed] do
      {:stop, :normal, recover(state.receipt), state}
    else
      {:reply, {:error, :not_terminal}, state}
    end
  end

  @impl true
  def handle_info(
        {:crawler_filesystem_terminate, owner, nonce, operation},
        %{owner: owner} = state
      )
      when is_reference(nonce) and operation in [:finish, :abort] do
    result = owned_cleanup(state, operation)
    send(owner, {:crawler_filesystem_terminal, self(), nonce, operation, result})
    {:stop, :normal, state}
  end

  def handle_info({:crawler_filesystem_terminate, _, _, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state) do
    case close_gate(state.gate) do
      :ok -> recover(state.receipt)
      {:error, :promotion_in_progress} -> :ok
    end

    {:stop, :normal, state}
  end

  def handle_info({:crawler_filesystem_activate, _, _}, state), do: {:noreply, state}

  defp owned_cleanup(state, operation) do
    allowed =
      if operation == :abort,
        do: close_gate(state.gate),
        else:
          if(:atomics.get(state.gate, 1) in [@promoted, @cancelled, @failed],
            do: :ok,
            else: {:error, :not_terminal}
          )

    with :ok <- allowed,
         {:ok, outcome} when outcome in [:promoted, :aborted] <- recover(state.receipt) do
      {:ok, outcome}
    else
      _ -> {:error, :cleanup_failed}
    end
  catch
    _, _ -> {:error, :cleanup_failed}
  end

  defp close_gate(gate) do
    case :atomics.get(gate, 1) do
      @committing ->
        {:error, :promotion_in_progress}

      @promoted ->
        :ok

      @failed ->
        :ok

      @cancelled ->
        :ok

      phase ->
        case :atomics.compare_exchange(gate, 1, phase, @cancelled) do
          :ok -> :ok
          _ -> close_gate(gate)
        end
    end
  end

  defp prepare_destination(%{mode: :managed} = receipt) do
    source = area_path(receipt, :archive)
    target = destination(receipt)

    with :ok <- validate_area(receipt, :archive),
         :ok <- missing(target),
         :ok <- append(receipt, {:promoting, :archive}) do
      {:ok, {source, receipt.area_ids.archive, target, :missing}}
    end
  end

  defp prepare_destination(%{mode: :standalone, file_path: path} = receipt) do
    source = Path.join(area_path(receipt, :archive), path)
    target = Path.join(receipt.root, path)

    with :ok <- validate_area(receipt, :archive),
         :ok <- source_identity(receipt, path),
         :ok <- parents(receipt, :root, Enum.drop(Path.split(path), -1)),
         :ok <- path_unowned(receipt, :root, target),
         :ok <- regular_or_missing(target),
         {:ok, source_id} <- raw_identity(source),
         {:ok, target_id} <- expected_target(target),
         :ok <- append(receipt, {:promoting, path}) do
      {:ok, {source, source_id, target, target_id}}
    end
  end

  defp prepared(state, {source, source_id, target, target_id}) do
    selected_owner = state.owner
    gate = state.gate
    receipt = state.receipt

    boundaries = [
      {receipt.root, receipt.root_id},
      {Path.join(receipt.root, @registry), receipt.registry_id},
      {receipt.claim, receipt.claim_id},
      {receipt.stage, receipt.stage_id}
    ]

    {@prepared_tag,
     fn operation ->
       if self() == selected_owner do
         prepared_operation(
           operation,
           gate,
           receipt,
           boundaries,
           source,
           source_id,
           target,
           target_id
         )
       else
         {:error, :not_owner}
       end
     end}
  end

  defp prepared_operation({:identity, recovery_receipt}, gate, receipt, _, _, _, _, _),
    do: recovery_receipt === receipt and :atomics.get(gate, 1) == @sealed

  defp prepared_operation(:promote, gate, _, boundaries, source, source_id, target, target_id),
    do: local_promote(gate, boundaries, source, source_id, target, target_id)

  defp prepared_operation(:cancel, gate, _, _, _, _, _, _), do: cancel_prepared(gate)

  defp cancel_prepared(gate) do
    case :atomics.compare_exchange(gate, 1, @sealed, @cancelled) do
      :ok -> :ok
      _ -> {:error, :closed}
    end
  end

  defp local_promote(gate, boundaries, source, source_id, target, target_id) do
    case :atomics.compare_exchange(gate, 1, @sealed, @committing) do
      :ok ->
        result =
          with :ok <- raw_boundaries(boundaries),
               :ok <- raw_matches(source, source_id),
               :ok <- target_matches(target, target_id) do
            :prim_file.rename(source, target)
          end

        :atomics.put(gate, 1, if(result == :ok, do: @promoted, else: @failed))
        result

      _ ->
        {:error, :closed}
    end
  end

  defp raw_boundaries(boundaries) do
    Enum.reduce_while(boundaries, :ok, fn {path, id}, :ok ->
      case raw_matches(path, id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp raw_identity(path) do
    with {:ok, info} <- :file.read_link_info(path, [:raw]) do
      {:ok, record_identity(info)}
    end
  end

  defp raw_matches(path, expected) do
    with {:ok, id} <- raw_identity(path) do
      if id == expected, do: :ok, else: {:error, :ownership_changed}
    end
  end

  defp expected_target(path) do
    case raw_identity(path) do
      {:ok, id} -> {:ok, id}
      {:error, :enoent} -> {:ok, :missing}
      error -> error
    end
  end

  defp target_matches(path, :missing) do
    case raw_identity(path) do
      {:error, :enoent} -> :ok
      {:ok, _} -> {:error, :destination_exists}
      error -> error
    end
  end

  defp target_matches(path, id), do: raw_matches(path, id)

  defp writable(%{sealed: true}), do: {:error, :sealed}
  defp writable(%{poisoned: true}), do: {:error, :failed}
  defp writable(_), do: :ok

  defp reservation(state, area, path, bytes) do
    limits = state.receipt.limits

    result =
      with :ok <- writable(state),
           true <- area in @areas or {:error, :invalid_area},
           :ok <- relative(path),
           true <- (is_integer(bytes) and bytes >= 0) or {:error, :invalid_size},
           true <- bytes <= limits.max_file_bytes or {:error, :file_limit},
           true <- state.bytes + bytes <= limits.max_bytes or {:error, :byte_limit},
           true <- state.files < limits.max_files or {:error, :file_count_limit},
           true <-
             area != :metadata or state.metadata_bytes + bytes <= limits.max_metadata_bytes or
               {:error, :metadata_limit},
           false <- MapSet.member?(state.paths, {area, path}) do
        :ok
      else
        true -> {:error, :eexist}
        error -> error
      end

    if result == :ok do
      ticket = make_ref()

      state = %{
        state
        | tickets: Map.put(state.tickets, ticket, {area, path, bytes}),
          paths: MapSet.put(state.paths, {area, path}),
          files: state.files + 1,
          bytes: state.bytes + bytes,
          metadata_bytes: state.metadata_bytes + if(area == :metadata, do: bytes, else: 0)
      }

      {{:ok, ticket}, state}
    else
      {result, state}
    end
  end

  defp write_reserved(state, ticket, bytes) do
    case Map.pop(state.tickets, ticket) do
      {nil, _} ->
        {{:error, :invalid_reservation}, state}

      {{area, path, size}, tickets} ->
        result =
          with :ok <- writable(state),
               true <-
                 (is_binary(bytes) and byte_size(bytes) == size) or {:error, :reservation_size},
               :ok <- validate_receipt(state.receipt),
               :ok <- validate_area(state.receipt, area),
               :ok <- parents(state.receipt, area, Enum.drop(Path.split(path), -1)) do
            create_file(state.receipt, area, path, bytes)
          end

        {result, %{state | tickets: tickets, poisoned: result != :ok}}
    end
  end

  defp setup(root, name, mode, file_path, limits) do
    case setup_classified(root, name, mode, file_path, limits) do
      {:error, _ownership, reason} -> {:error, reason}
      result -> result
    end
  end

  defp setup_classified(root, name, mode, file_path, limits) do
    root = Path.expand(root)

    with :ok <- isolated(root),
         :ok <- unmanaged(root),
         {:ok, root_id} <- identity(root),
         :ok <- fresh_destination(root, name, mode),
         :ok <- ensure_registry(root),
         {:ok, registry_id} <- identity(Path.join(root, @registry)),
         claim = claim_path(root, name),
         :ok <- claim(claim) do
      case bootstrap(root, name, mode, file_path, limits, root_id, registry_id, claim) do
        {:ok, _} = result -> result
        {:error, reason} -> {:error, :partial, reason}
      end
    else
      {:error, {:incomplete_claim, _} = reason} -> {:error, :partial, reason}
      {:error, reason} -> {:error, :unclaimed, reason}
    end
  end

  defp bootstrap(root, name, mode, file_path, limits, root_id, registry_id, claim) do
    id = random()
    stage = Path.join(root, @prefix <> id)
    header = :erlang.term_to_binary({1, id, random(), mode, name, file_path, limits})

    with :ok <- private(claim),
         {:ok, claim_id} <- identity(claim),
         :ok <- File.mkdir(stage),
         :ok <- File.chmod(stage, 0o700),
         {:ok, stage_id} <- identity(stage),
         :ok <- File.write(Path.join(claim, "owner"), header, [:exclusive]),
         {:ok, header_id} <- identity(Path.join(claim, "owner")),
         :ok <- File.write(Path.join(claim, "journal"), "", [:exclusive]),
         {:ok, journal_id} <- identity(Path.join(claim, "journal")) do
      Process.put(@journal_count, 0)

      receipt = %{
        root: root,
        root_id: root_id,
        registry_id: registry_id,
        destination: name,
        mode: mode,
        file_path: file_path,
        id: id,
        claim: claim,
        claim_id: claim_id,
        stage: stage,
        stage_id: stage_id,
        header: header,
        header_id: header_id,
        journal_id: journal_id,
        limits: limits
      }

      case make_areas(receipt) do
        :ok ->
          area_ids =
            Map.new(@areas, fn area ->
              {:ok, id} = identity(area_path(receipt, area))
              {area, id}
            end)

          {:ok, Map.put(receipt, :area_ids, area_ids)}

        {:error, reason} ->
          {:error, {:setup, reason, receipt}}
      end
    else
      {:error, reason} -> {:error, {:incomplete_claim, reason}}
    end
  end

  defp claim(path) do
    case File.mkdir(path) do
      :ok ->
        case File.chmod(path, 0o700) do
          :ok -> :ok
          {:error, reason} -> {:error, {:incomplete_claim, reason}}
        end

      {:error, :eexist} ->
        {:error, :destination_owned}

      error ->
        error
    end
  end

  defp fresh_destination(_, _, :standalone), do: :ok
  defp fresh_destination(root, name, :managed), do: missing(Path.join(root, name))

  defp parents(receipt, area, parts) do
    Enum.reduce_while(parts, "", fn part, prefix ->
      path = if prefix == "", do: part, else: Path.join(prefix, part)
      full = Path.join(area_path(receipt, area), path)

      result =
        with :ok <- path_unowned(receipt, area, full) do
          case File.lstat(full) do
            {:ok, %{type: :directory}} -> parent_policy(full, area)
            {:error, :enoent} -> make_directory(receipt, area, path)
            {:ok, _} -> {:error, :unsafe_path}
            error -> error
          end
        end

      case result do
        :ok -> {:cont, path}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp path_unowned(receipt, :root, path) do
    claim = claim_path(Path.dirname(path), Path.basename(path))

    if claim == receipt.claim do
      :ok
    else
      claim_available(Path.dirname(path), Path.basename(path))
    end
  end

  defp path_unowned(_, _, _), do: :ok

  defp parent_policy(path, :root) do
    with {uid_text, 0} <- System.cmd("id", ["-u"]),
         do: safe_parent(path, String.to_integer(String.trim(uid_text)))
  end

  defp parent_policy(path, _), do: private(path)

  defp make_directory(receipt, area, path) do
    full = Path.join(area_path(receipt, area), path)

    with :ok <- journal_room(receipt),
         :ok <- ancestry(Path.dirname(full)),
         :ok <- File.mkdir(full),
         :ok <- File.chmod(full, 0o700),
         {:ok, id} <- identity(full) do
      append(receipt, {:entry, area, path, id})
    end
  end

  defp create_file(receipt, area, path, bytes) do
    full = Path.join(area_path(receipt, area), path)

    with :ok <- journal_room(receipt),
         :ok <- ancestry(Path.dirname(full)),
         {:ok, file} <- File.open(full, [:write, :binary, :exclusive, :raw]) do
      try do
        with {:ok, info} <- :file.read_file_info(file),
             id = record_identity(info),
             :ok <- append(receipt, {:entry, area, path, id}),
             :ok <- :file.write(file, bytes) do
          :file.sync(file)
        end
      after
        File.close(file)
      end
    end
  end

  defp journal_room(receipt) do
    with :ok <- matches(journal(receipt), receipt.journal_id),
         {:ok, stat} <- File.lstat(journal(receipt)),
         true <- stat.size + 4096 <= receipt.limits.max_journal_bytes or {:error, :journal_limit},
         true <-
           Process.get(@journal_count, 0) < receipt.limits.max_entries or {:error, :entry_limit} do
      :ok
    end
  end

  defp append(receipt, entry) do
    bytes = :erlang.term_to_binary(entry)
    frame = <<byte_size(bytes)::32, bytes::binary>>

    with :ok <- journal_room(receipt),
         {:ok, file} <- File.open(journal(receipt), [:append, :binary, :raw]) do
      try do
        with :ok <- :file.write(file, frame),
             :ok <- :file.sync(file) do
          Process.put(@journal_count, Process.get(@journal_count, 0) + 1)
          :ok
        end
      after
        File.close(file)
      end
    end
  end

  defp read_journal(receipt) do
    with :ok <- matches(journal(receipt), receipt.journal_id),
         {:ok, bytes} <- bounded_read(journal(receipt), receipt.limits.max_journal_bytes) do
      decode(bytes, [], receipt.limits.max_entries)
    end
  end

  defp decode(<<>>, entries, _), do: {:ok, Enum.reverse(entries)}
  defp decode(<<_size::32, 131, 80, _::binary>>, _, _), do: {:error, :invalid_journal}

  defp decode(<<size::32, rest::binary>>, entries, count)
       when size <= 4096 and byte_size(rest) >= size and count > 0 do
    <<entry::binary-size(size), tail::binary>> = rest

    with {:ok, value} <- decode_entry(entry) do
      decode(tail, [value | entries], count - 1)
    end
  end

  defp decode(_, _, _), do: {:error, :invalid_journal}

  defp decode_entry(entry) do
    try do
      case :erlang.binary_to_term(entry, [:safe]) do
        {:entry, area, path, {type, major, minor, inode}} = value
        when area in [:stage, :root | @areas] and type in [:regular, :directory] and
               is_integer(major) and major >= 0 and is_integer(minor) and minor >= 0 and
               is_integer(inode) and inode > 0 ->
          if relative(path) == :ok, do: {:ok, value}, else: {:error, :invalid_journal}

        {:promoting, :archive} = value ->
          {:ok, value}

        {:promoting, path} = value when is_binary(path) ->
          if relative(path) == :ok, do: {:ok, value}, else: {:error, :invalid_journal}

        _ ->
          {:error, :invalid_journal}
      end
    rescue
      ArgumentError -> {:error, :invalid_journal}
    end
  end

  defp cleanup(receipt, entries) do
    with {:ok, outcome} <- promotion_outcome(receipt, entries),
         :ok <- remove_entries(receipt, entries, outcome),
         :ok <- remove_matching(receipt.stage, receipt.stage_id) do
      if outcome == :promoted and receipt.mode == :managed do
        {:ok, :promoted}
      else
        with :ok <- remove_matching(journal(receipt), receipt.journal_id),
             :ok <- remove_matching(Path.join(receipt.claim, "owner"), receipt.header_id),
             :ok <- remove_matching(receipt.claim, receipt.claim_id) do
          {:ok, outcome}
        end
      end
    end
  end

  defp promotion_outcome(receipt, entries) do
    intent = Enum.find(Enum.reverse(entries), &match?({:promoting, _}, &1))

    case intent do
      nil ->
        {:ok, :aborted}

      {:promoting, path} ->
        {area, source, target} =
          if path == :archive do
            {:stage, "archive", destination(receipt)}
          else
            {:archive, path, Path.join(receipt.root, path)}
          end

        case Enum.find(entries, &match?({:entry, ^area, ^source, _}, &1)) do
          {:entry, _, _, id} ->
            case {matches(target, id), File.lstat(Path.join(area_path(receipt, area), source))} do
              {:ok, {:error, :enoent}} -> {:ok, :promoted}
              {_, {:ok, _}} -> {:ok, :aborted}
              _ -> {:error, :promotion_uncertain}
            end

          nil ->
            {:error, :invalid_journal}
        end
    end
  end

  defp remove_entries(receipt, entries, outcome) do
    entries
    |> Enum.reverse()
    |> Enum.reduce_while(:ok, fn
      {:entry, area, path, id}, :ok ->
        full = Path.join(area_path(receipt, area), path)
        skip = outcome == :promoted and (area == :root or promoted_entry?(receipt, area, path))

        result = if skip, do: :ok, else: remove_matching(full, id)

        case result do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      _, :ok ->
        {:cont, :ok}
    end)
  end

  defp promoted_entry?(%{mode: :managed}, area, path),
    do: area == :archive or (area == :stage and path == "archive")

  defp promoted_entry?(_, _, _), do: false

  defp remove_matching(path, id) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, stat} ->
        with :ok <- ancestry(Path.dirname(path)),
             true <- stat_identity(stat) == id or {:error, :ownership_changed} do
          if stat.type == :directory, do: File.rmdir(path), else: File.rm(path)
        end

      error ->
        error
    end
  end

  defp validate_receipt(receipt) do
    with :ok <- isolated(receipt.root),
         :ok <- matches(receipt.root, receipt.root_id),
         :ok <- ancestry(receipt.claim),
         :ok <- matches(receipt.claim, receipt.claim_id),
         :ok <- matches(Path.join(receipt.claim, "owner"), receipt.header_id),
         {:ok, header} <- bounded_read(Path.join(receipt.claim, "owner"), 4096),
         true <- header == receipt.header or {:error, :ownership_changed},
         :ok <- stage_or_missing(receipt) do
      :ok
    end
  end

  defp validate_area(receipt, area) do
    with :ok <- ancestry(area_path(receipt, area)) do
      matches(area_path(receipt, area), Map.fetch!(receipt.area_ids, area))
    end
  end

  defp source_identity(receipt, path) do
    with {:ok, entries} <- read_journal(receipt),
         {:entry, :archive, ^path, id} <-
           Enum.find(entries, &match?({:entry, :archive, ^path, _}, &1)),
         :ok <- ancestry(Path.dirname(Path.join(area_path(receipt, :archive), path))) do
      matches(Path.join(area_path(receipt, :archive), path), id)
    else
      nil -> {:error, :invalid_journal}
      error -> error
    end
  end

  defp stage_or_missing(receipt) do
    case File.lstat(receipt.stage) do
      {:error, :enoent} -> :ok
      {:ok, _} -> matches(receipt.stage, receipt.stage_id)
      error -> error
    end
  end

  defp bounded_read(path, limit) do
    with {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        case :file.read(file, limit + 1) do
          :eof -> {:ok, ""}
          {:ok, bytes} when byte_size(bytes) <= limit -> {:ok, bytes}
          {:ok, _} -> {:error, :metadata_limit}
          error -> error
        end
      after
        File.close(file)
      end
    end
  end

  defp ensure_registry(root) do
    registry = Path.join(root, @registry)

    case File.mkdir(registry) do
      :ok ->
        with :ok <- File.chmod(registry, 0o700) do
          File.write(Path.join(registry, @registry_marker), @registry_header <> random(), [
            :exclusive
          ])
        end

      {:error, :eexist} ->
        registry_owned(registry)

      error ->
        error
    end
  end

  defp registry_owned(registry) do
    with :ok <- private(registry),
         {:ok, %{type: :regular, links: 1}} <- File.lstat(Path.join(registry, @registry_marker)),
         {:ok, <<@registry_header, id::binary-size(32)>>} <-
           bounded_read(Path.join(registry, @registry_marker), 128),
         true <- String.match?(id, ~r/\A[A-Za-z0-9_-]+\z/) do
      :ok
    else
      _ -> {:error, :destination_owned}
    end
  end

  defp claim_available(root, name) do
    registry = Path.join(root, @registry)

    case File.lstat(registry) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: :directory}} ->
        with :ok <- registry_owned(registry) do
          case File.lstat(claim_path(root, name)) do
            {:error, :enoent} -> :ok
            {:ok, _} -> {:error, :destination_owned}
            error -> error
          end
        end

      {:ok, _} ->
        {:error, :unsafe_path}

      error ->
        error
    end
  end

  defp unmanaged(path) do
    Enum.reduce_while(ancestors(path), :ok, fn part, :ok ->
      case claim_available(Path.dirname(part), Path.basename(part)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp ancestry(path) do
    Enum.reduce_while(ancestors(path), :ok, fn part, :ok ->
      case File.lstat(part) do
        {:ok, %{type: :directory}} -> {:cont, :ok}
        {:ok, _} -> {:halt, {:error, :unsafe_path}}
        error -> {:halt, error}
      end
    end)
  end

  defp ancestors(path) do
    path |> Path.split() |> Enum.scan(&Path.join(&2, &1))
  end

  defp make_areas(receipt) do
    Enum.reduce_while(@areas, :ok, fn area, :ok ->
      case make_directory(receipt, :stage, Atom.to_string(area)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp isolated_ancestor(path, uid) do
    case File.lstat(path) do
      {:ok, %{type: :directory} = stat} ->
        trusted_owner = stat.uid in [0, uid]
        shared = (stat.mode &&& 0o022) != 0
        sticky = (stat.mode &&& 0o1000) != 0

        if trusted_owner and (not shared or sticky),
          do: {:cont, :ok},
          else: {:halt, {:error, :unsafe_root}}

      {:ok, _} ->
        {:halt, {:error, :unsafe_path}}

      error ->
        {:halt, error}
    end
  end

  defp isolated(root) do
    with :ok <- ancestry(root),
         {uid_text, 0} <- System.cmd("id", ["-u"]),
         uid = String.to_integer(String.trim(uid_text)),
         :ok <- safe_parent(root, uid) do
      Enum.reduce_while(ancestors(root), :ok, fn path, :ok -> isolated_ancestor(path, uid) end)
    else
      {:error, _} = error -> error
      _ -> {:error, :unsafe_root}
    end
  end

  defp safe_parent(path, uid) do
    case File.lstat(path) do
      {:ok, %{type: :directory, uid: ^uid} = stat} ->
        if (stat.mode &&& 0o022) == 0 and (stat.mode &&& 0o700) == 0o700,
          do: :ok,
          else: {:error, :unsafe_root}

      {:ok, _} ->
        {:error, :unsafe_root}

      error ->
        error
    end
  end

  defp private(path) do
    with {uid_text, 0} <- System.cmd("id", ["-u"]) do
      private(path, String.to_integer(String.trim(uid_text)))
    else
      _ -> {:error, :unsafe_root}
    end
  end

  defp private(path, uid) do
    case File.lstat(path) do
      {:ok, %{type: :directory, uid: ^uid} = stat} ->
        if (stat.mode &&& 0o777) == 0o700, do: :ok, else: {:error, :unsafe_root}

      {:ok, _} ->
        {:error, :unsafe_root}

      error ->
        error
    end
  end

  defp identity(path) do
    with {:ok, stat} <- File.lstat(path), do: {:ok, stat_identity(stat)}
  end

  defp stat_identity(stat), do: {stat.type, stat.major_device, stat.minor_device, stat.inode}
  defp record_identity(info), do: {elem(info, 2), elem(info, 9), elem(info, 10), elem(info, 11)}

  defp matches(path, id) do
    with {:ok, actual} <- identity(path) do
      if actual == id, do: :ok, else: {:error, :ownership_changed}
    end
  end

  defp missing(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _} -> {:error, :destination_exists}
      error -> error
    end
  end

  defp regular_or_missing(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :regular, links: 1}} -> :ok
      {:ok, _} -> {:error, :unsafe_path}
      error -> error
    end
  end

  defp relative(path) when is_binary(path) and byte_size(path) <= 1024 do
    parts = String.split(path, "/")

    if length(parts) <= 16 and Enum.all?(parts, &(name(&1) == :ok)),
      do: :ok,
      else: {:error, :invalid_path}
  end

  defp relative(_), do: {:error, :invalid_path}

  defp name(name) when is_binary(name) do
    if byte_size(name) in 1..255 and String.valid?(name) and name not in [".", ".."] and
         not String.starts_with?(String.downcase(name), @prefix) and
         not String.contains?(name, ["/", "\\", <<0>>]),
       do: :ok,
       else: {:error, :invalid_path}
  end

  defp name(_), do: {:error, :invalid_path}

  defp options(opts) do
    if is_list(opts) and Keyword.keyword?(opts) do
      {owner, limits_opts} = Keyword.pop(opts, :owner, self())

      with true <-
             (is_pid(owner) and node(owner) == node() and Process.alive?(owner)) or
               {:error, :invalid_owner},
           {:ok, limits} <- limits(limits_opts) do
        {:ok, owner, limits}
      end
    else
      {:error, :invalid_limits}
    end
  end

  defp limits(opts) do
    if Enum.all?(opts, fn {key, value} ->
         Map.has_key?(@defaults, key) and is_integer(value) and value > 0
       end) do
      {:ok, Map.merge(@defaults, Map.new(opts))}
    else
      {:error, :invalid_limits}
    end
  end

  defp area_path(receipt, :root), do: receipt.root
  defp area_path(receipt, :stage), do: receipt.stage
  defp area_path(receipt, area), do: Path.join(receipt.stage, Atom.to_string(area))
  defp destination(receipt), do: Path.join(receipt.root, receipt.destination)
  defp journal(receipt), do: Path.join(receipt.claim, "journal")

  defp claim_path(root, name), do: Path.join([root, @registry, name])

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
end
