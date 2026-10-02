defmodule Crawler.Charset do
  @moduledoc false

  alias Crawler.Charset.CSS
  alias Crawler.Charset.Encoding
  alias Crawler.Charset.HTML
  alias Crawler.Charset.Labels
  alias Crawler.MediaType

  def decode(body, opts) when is_binary(body) do
    if textual?(opts[:content_type]), do: transcode(body, opts), else: body
  end

  def decode(body, _opts), do: body

  defp textual?(type) do
    MediaType.text?(type) or MediaType.javascript?(type) or MediaType.xhtml?(type)
  end

  defp transcode(body, opts) do
    decoded =
      case Encoding.bom(body) do
        {:utf8, rest} -> Encoding.to_utf8(rest)
        {:utf16, endian, rest} -> Encoding.to_utf16(rest, endian)
        :none -> Encoding.decode_label(body, declared_charset(body, opts) || "utf-8")
      end

    cond do
      MediaType.xhtml?(opts[:content_type]) ->
        decoded |> HTML.declare_xml_utf8() |> HTML.declare_utf8()

      MediaType.html?(opts[:content_type]) ->
        HTML.declare_utf8(decoded)

      MediaType.css?(opts[:content_type]) ->
        CSS.declare_utf8(decoded)

      true ->
        decoded
    end
  end

  defp declared_charset(body, opts) do
    Labels.http_charset(opts[:headers]) || document_charset(body, opts[:content_type])
  end

  defp document_charset(body, content_type) do
    cond do
      MediaType.xhtml?(content_type) -> HTML.xml_charset(body) || HTML.charset(body)
      MediaType.html?(content_type) -> HTML.charset(body)
      MediaType.css?(content_type) -> CSS.charset(body)
      true -> nil
    end
  end
end
