defmodule Crawler.Parser.JsParser.Matches do
  @moduledoc false

  def reduce(regex, source, acc, fun), do: next(regex, source, 0, acc, fun)

  defp next(regex, source, offset, acc, fun) when offset <= byte_size(source) do
    case Regex.run(regex, source, return: :index, offset: offset) do
      nil ->
        {:ok, acc}

      [{at, len} | _] = groups ->
        case fun.(groups, acc) do
          {:cont, acc} -> next(regex, source, max(at + len, at + 1), acc, fun)
          {:halt, result} -> result
        end
    end
  end

  defp next(_regex, _source, _offset, acc, _fun), do: {:ok, acc}
end
