defmodule Crawler.Store.Budget do
  @moduledoc false

  def status(ops, inflight, limit) when is_integer(limit) do
    cond do
      ops >= limit -> :full
      ops + inflight >= limit -> :wait
      true -> :ok
    end
  end

  def status(_ops, _inflight, _limit), do: :ok
end
