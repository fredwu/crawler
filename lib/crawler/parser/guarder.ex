defmodule Crawler.Parser.Guarder do
  @moduledoc """
  Detects whether a page is parsable.
  """

  @doc """
  ## Examples

      iex> Guarder.pass?(
      iex>   %{html_tag: "link"}
      iex> )
      true

      iex> Guarder.pass?(
      iex>   %{html_tag: "img"}
      iex> )
      false

      iex> Guarder.pass?(
      iex>   %{html_tag: "link", headers: [{"Content-Type", "image/png"}]}
      iex> )
      false

      iex> Guarder.pass?(
      iex>   %{html_tag: "link", headers: [{"content-type", "image/png"}]}
      iex> )
      false
  """
  def pass?(opts) do
    is_text_link?(opts[:html_tag]) && is_text_file?(opts[:headers])
  end

  defp is_text_link?(html_tag) do
    Enum.member?(["a", "link"], html_tag)
  end

  defp is_text_file?(nil), do: true

  defp is_text_file?(headers) do
    String.starts_with?(content_type(headers), "text")
  end

  defp content_type(headers) do
    case Enum.find(headers, &find_content_type/1) do
      {_, value} -> value
      _          -> "text"
    end
  end

  defp find_content_type({header, _}), do: String.downcase(header) == "content-type"
end
