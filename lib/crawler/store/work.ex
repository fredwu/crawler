defmodule Crawler.Store.Work do
  @moduledoc false

  alias Crawler.Store.Budget

  defstruct pending: 0, inflight: 0, pages: MapSet.new(), deferred: :queue.new()

  def defer(work, opts), do: %{work | deferred: :queue.in(opts, work.deferred)}

  def resume(work, ops, inflight, ready_count) do
    {ready, waiting, dropped, ready_count} =
      Enum.reduce(:queue.to_list(work.deferred), {[], [], 0, ready_count}, fn opts,
                                                                              {ready, waiting,
                                                                               dropped, count} ->
        case Budget.status(ops, inflight + count, opts[:max_pages]) do
          :ok -> {[opts | ready], waiting, dropped, count + 1}
          :wait -> {ready, [opts | waiting], dropped, count}
          :full -> {ready, waiting, dropped + 1, count}
        end
      end)

    work = %{
      work
      | pending: max(work.pending - dropped, 0),
        deferred: waiting |> Enum.reverse() |> :queue.from_list()
    }

    {work, Enum.reverse(ready), ready_count}
  end
end
