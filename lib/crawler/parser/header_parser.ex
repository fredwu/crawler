defmodule Crawler.Parser.HeaderParser do
  @moduledoc """
  Captures and parses HTTP response headers.
  """

  @default_content_type "text/html"

  @doc """
  ## Examples

      iex> HeaderParser.parse(
      iex>   %{}
      iex> )
      %{content_type: "text/html"}

      iex> HeaderParser.parse(
      iex>   %{headers: [{"Content-Type", "text/css"}]}
      iex> )
      %{headers: [{"Content-Type", "text/css"}], content_type: "text/css"}

      iex> HeaderParser.parse(
      iex>   %{headers: [{"Content-Type", "image/png; blah"}]}
      iex> )
      %{headers: [{"Content-Type", "image/png; blah"}], content_type: "image/png"}
  """
  def parse(opts) do
    content_type = opts[:headers]
    |> get_content_type
    |> simplify_content_type

    Map.put(opts, :content_type, content_type)
  end

  defp get_content_type(nil), do: @default_content_type

  defp get_content_type(headers) do
    case Enum.find(headers, &find_content_type/1) do
      {_, value} -> value
      _          -> @default_content_type
    end
  end

  defp find_content_type({header, _}) do
    String.downcase(header) == "content-type"
  end

  defp simplify_content_type(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> Kernel.hd
  end
end
