defmodule Crawler.Fetcher.HeaderPreparer do
  @moduledoc """
  Captures and prepares HTTP response headers.
  """

  alias Crawler.MediaType

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

      iex> HeaderPreparer.prepare(
      iex>   [{"Content-Type", "Text/HTML; charset=UTF-8"}],
      iex>   %{}
      iex> )
      %{headers: [{"Content-Type", "Text/HTML; charset=UTF-8"}], content_type: "text/html"}

      iex> HeaderPreparer.prepare(
      iex>   [{"Content-Type", "text/css ; charset=utf-8"}],
      iex>   %{}
      iex> )
      %{headers: [{"Content-Type", "text/css ; charset=utf-8"}], content_type: "text/css"}

      iex> HeaderPreparer.prepare([], %{})
      %{headers: [], content_type: nil}

      iex> HeaderPreparer.prepare([{"Content-Type", "  "}], %{})
      %{headers: [{"Content-Type", "  "}], content_type: nil}
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

  defp get_content_type(nil), do: nil

  defp get_content_type(headers) do
    case Enum.find(headers, &content_type_header?/1) do
      {_, value} when is_binary(value) -> present(value)
      _ -> nil
    end
  end

  defp content_type_header?({header, _}) do
    String.downcase(to_string(header)) == "content-type"
  end

  defp present(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp simplify_content_type(nil), do: nil
  defp simplify_content_type(content_type), do: MediaType.normalize(content_type)
end
