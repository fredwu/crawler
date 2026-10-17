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

      iex> Guarder.pass?(
      iex>   %{html_tag: "a", content_type: "image/svg+xml"}
      iex> )
      true

      iex> Guarder.pass?(
      iex>   %{html_tag: "img", content_type: "image/svg+xml"}
      iex> )
      false

      iex> Guarder.pass?(
      iex>   %{html_tag: "a", content_type: "image/svg+xml; charset=utf-8"}
      iex> )
      true

      iex> Guarder.pass?(
      iex>   %{html_tag: "a", content_type: "text/plain"}
      iex> )
      false

      iex> Guarder.pass?(
      iex>   %{html_tag: "link", content_type: "text/html"}
      iex> )
      false

      iex> Guarder.pass?(
      iex>   %{html_tag: "script", content_type: "text/html"}
      iex> )
      false

      iex> Guarder.pass?(
      iex>   %{html_tag: "a", content_type: "text/css"}
      iex> )
      true

      iex> Guarder.pass?(
      iex>   %{html_tag: "a", content_type: "text/javascript"}
      iex> )
      true

      iex> Guarder.pass?(
      iex>   %{html_tag: "a", content_type: "text/html"}
      iex> )
      true

      iex> Guarder.pass?(
      iex>   %{html_tag: "fetch", content_type: "text/html"}
      iex> )
      false
  """
  def pass?(opts) do
    type = opts[:content_type]
    tag = opts[:html_tag]

    cond do
      MediaType.svg?(type) -> tag == "a"
      tag not in ["a", "link", "script"] -> false
      MediaType.css?(type) or MediaType.javascript?(type) -> true
      MediaType.html?(type) -> tag == "a"
      true -> false
    end
  end
end
