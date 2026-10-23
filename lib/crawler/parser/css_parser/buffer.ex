defmodule Crawler.Parser.CssParser.Buffer do
  @moduledoc false

  alias Crawler.Analysis.Budget

  @overhead 512

  def new(budget) do
    budget = take!(Budget.reserve(budget, @overhead))
    %{chunks: [], bytes: 0, cells: 0, scratch: @overhead, budget: budget}
  end

  def push(buffer, byte) when is_integer(byte) do
    buffer = reserve(buffer, Budget.cost(:list_cell))
    %{buffer | chunks: [byte | buffer.chunks], bytes: buffer.bytes + 1, cells: buffer.cells + 1}
  end

  def escaped(buffer, source) do
    buffer = reserve(buffer, Budget.cost(:list_cell) + Budget.cost(:binary) + 4)
    {decoded, rest} = Crawler.Parser.CssParser.Identifier.decode_escape(source)

    {%{
       buffer
       | chunks: [decoded | buffer.chunks],
         bytes: buffer.bytes + byte_size(decoded),
         cells: buffer.cells + 1
     }, rest}
  end

  def replacement(buffer) do
    buffer = reserve(buffer, Budget.cost(:list_cell) + Budget.cost(:binary) + 3)

    %{
      buffer
      | chunks: [<<0xFFFD::utf8>> | buffer.chunks],
        bytes: buffer.bytes + 3,
        cells: buffer.cells + 1
    }
  end

  def finish(buffer) do
    reverse_bytes = Budget.cost(:list_cell, buffer.cells)
    budget = take!(Budget.reserve(buffer.budget, reverse_bytes))
    budget = take!(Budget.charge(budget, Budget.cost(:binary) + buffer.bytes))
    value = buffer.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    budget = take!(Budget.release(budget, buffer.scratch + reverse_bytes))
    {value, budget}
  end

  defp reserve(buffer, bytes) do
    budget = take!(Budget.reserve(buffer.budget, bytes))
    %{buffer | budget: budget, scratch: buffer.scratch + bytes}
  end

  defp take!({:ok, budget}), do: budget
  defp take!({:error, reason}), do: throw({:css_budget, reason})
end
