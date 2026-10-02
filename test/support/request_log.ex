defmodule Crawler.RequestLog do
  @moduledoc false

  def new, do: :ets.new(__MODULE__, [:duplicate_bag, :public])

  def record(table, request), do: :ets.insert(table, {request})

  def entries(table) do
    Enum.map(:ets.tab2list(table), fn {request} -> request end)
  end

  def frequencies(table), do: table |> entries() |> Enum.frequencies()
end
