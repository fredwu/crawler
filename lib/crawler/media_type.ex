defmodule Crawler.MediaType do
  @moduledoc false

  @javascript ~w(
    text/javascript
    application/javascript
    application/x-javascript
    text/ecmascript
    application/ecmascript
  )

  def normalize(type) when is_binary(type) do
    type
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end

  def normalize(_type), do: "text/html"

  def html?(type) do
    type = normalize(type)

    String.starts_with?(type, "text/html") or String.starts_with?(type, "application/xhtml")
  end

  def css?(type), do: normalize(type) == "text/css"

  def javascript?(type), do: normalize(type) in @javascript

  def text?(type), do: String.starts_with?(normalize(type), "text")

  def xhtml?(type), do: String.starts_with?(normalize(type), "application/xhtml")
end
