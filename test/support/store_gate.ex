defmodule Crawler.StoreGate do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  def hold(worker, matches?) do
    observer = self()
    store = Process.whereis(Crawler.Store)
    hook = make_ref()

    callback = fn
      :armed, {:in, {:"$gen_call", {^worker, _}, request}}, _ ->
        if matches?.(request) do
          :erlang.suspend_process(worker)
          send(observer, {:store_call_held, worker, request})
          :done
        else
          :armed
        end

      state, _event, _name ->
        state
    end

    assert :ok = :sys.install(store, {hook, callback, :armed})
    gate = %{store: store, worker: worker}

    on_exit(fn ->
      resume(gate)
      if Process.alive?(store), do: :sys.remove(store, hook)
    end)

    gate
  end

  def resume(%{store: store, worker: worker}) do
    if Process.alive?(store) do
      :sys.replace_state(store, &resume_worker(&1, worker))
    end
  end

  defp resume_worker(state, worker) do
    # Only the Store that suspended the worker can release this suspension.
    if Process.info(worker, :status) == {:status, :suspended},
      do: :erlang.resume_process(worker)

    state
  end
end
