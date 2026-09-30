defmodule Crawler.Parser.Guarder do
  @moduledoc """
  Detects whether a page is parsable.
  """

  alias Crawler.MediaType

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
    parsable_tag?(opts[:html_tag]) and parsable_type?(opts[:content_type])
  end

  defp parsable_tag?(html_tag), do: html_tag in ["a", "link", "script"]

  defp parsable_type?(content_type) do
    MediaType.text?(content_type) or MediaType.xhtml?(content_type) or
      MediaType.javascript?(content_type)
  end
end
