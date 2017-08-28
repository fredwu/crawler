defmodule Crawler.Parser.Guarder do
  @moduledoc """
  Detects whether a page is parsable.
  """

  @doc """
  Detects whether a page is parsable.

  ## Examples

      iex> Guarder.pass?(
      iex>   %{html_tag: "link", content_type: "text/css"}
      iex> )
      true

      iex> Guarder.pass?(
      iex>   %{html_tag: "img", content_type: "text/css"}
      iex> )
      false

      iex> Guarder.pass?(
      iex>   %{html_tag: "link", content_type: "text/css"}
      iex> )
      true

      iex> Guarder.pass?(
      iex>   %{html_tag: "link", content_type: "image/png"}
      iex> )
      false
  """
  def pass?(opts) do
    is_text_link?(opts[:html_tag]) && is_text_file?(opts[:content_type])
  end

  defp is_text_link?(html_tag), do: Enum.member?(["a", "link"], html_tag)

  defp is_text_file?(content_type), do: String.starts_with?(content_type, "text")
end
