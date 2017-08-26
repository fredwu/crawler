defmodule Crawler.Parser.Guarder do
  @moduledoc """
  Detects whether a page is parsable.
  """

  @doc """
  ## Examples

      iex> Guarder.pass?(
      iex>   "",
      iex>   %{html_tag: "link"}
      iex> )
      true

      iex> Guarder.pass?(
      iex>   "",
      iex>   %{html_tag: "img"}
      iex> )
      false

      iex> Guarder.pass?(
      iex>   "",
      iex>   %{html_tag: "link", headers: [{"Content-Type", "image/png"}]}
      iex> )
      false

      iex> Guarder.pass?(
      iex>   image_file(),
      iex>   %{html_tag: "link"}
      iex> )
      false
  """
  def pass?(body, opts) do
    is_text_link?(opts[:html_tag])
      && is_text_file?(opts[:headers])
      && String.valid?(body)
  end

  defp is_text_link?(html_tag) do
    Enum.member?(["a", "link"], html_tag)
  end

  defp is_text_file?(nil), do: true

  defp is_text_file?(headers) do
    String.starts_with?(content_type(headers), "text")
  end

  defp content_type(headers) do
    case Enum.find(headers, fn({h, _}) -> h == "Content-Type" end) do
      {_, value} -> value
      _          -> "text"
    end
  end
end
