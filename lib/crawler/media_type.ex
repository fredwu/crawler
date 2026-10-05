defmodule Crawler.MediaType do
  @moduledoc false

  @javascript ~w(
    application/ecmascript
    application/javascript
    application/x-ecmascript
    application/x-javascript
    text/ecmascript
    text/javascript
    text/javascript1.0
    text/javascript1.1
    text/javascript1.2
    text/javascript1.3
    text/javascript1.4
    text/javascript1.5
    text/jscript
    text/livescript
    text/x-ecmascript
    text/x-javascript
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

    type in ["text/html", "application/xhtml+xml"]
  end

  def css?(type), do: normalize(type) == "text/css"

  def javascript?(type), do: normalize(type) in @javascript

  def text?(type), do: String.starts_with?(normalize(type), "text/")

  def xhtml?(type), do: normalize(type) == "application/xhtml+xml"
end
