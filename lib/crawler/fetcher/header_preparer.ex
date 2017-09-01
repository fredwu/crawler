defmodule Crawler.Fetcher.HeaderPreparer do
  @moduledoc """
  Captures and prepares HTTP response headers.
  """

  @default_content_type "text/html"

  @doc """
  Captures and prepares HTTP response headers.

  ## Examples

      iex> HeaderPreparer.prepare(
      iex>   [{"Content-Type", "text/html"}],
      iex>   %{}
      iex> )
      %{headers: [{"Content-Type", "text/html"}], content_type: "text/html"}

      iex> HeaderPreparer.prepare(
      iex>   [{"Content-Type", "text/css"}],
      iex>   %{}
      iex> )
      %{headers: [{"Content-Type", "text/css"}], content_type: "text/css"}

      iex> HeaderPreparer.prepare(
      iex>   [{"Content-Type", "image/png; blah"}],
      iex>   %{}
      iex> )
      %{headers: [{"Content-Type", "image/png; blah"}], content_type: "image/png"}
  """
  def prepare(headers, opts) do
    content_type =
      headers
      |> get_content_type()
      |> simplify_content_type()

    opts
    |> Map.put(:headers, headers)
    |> Map.put(:content_type, content_type)
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
    |> Kernel.hd()
  end
end
