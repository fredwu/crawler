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

  # A BOM-less UTF-16 document that starts with "<?xml". Nil when the bytes do not.
  def utf16_xml(<<0x3C, 0x00, 0x3F, 0x00, 0x78, 0x00, 0x6D, 0x00, 0x6C, 0x00, _::binary>> = body) do
    Encoding.to_utf16(body, :little)
  end

  def utf16_xml(<<0x00, 0x3C, 0x00, 0x3F, 0x00, 0x78, 0x00, 0x6D, 0x00, 0x6C, _::binary>> = body) do
    Encoding.to_utf16(body, :big)
  end

  def utf16_xml(_body), do: nil

  defp textual?(type) do
    MediaType.text?(type) or MediaType.javascript?(type) or MediaType.xhtml?(type)
  end

  defp transcode(body, opts) do
    decoded =
      case Encoding.bom(body) do
        {:utf8, rest} ->
          Encoding.to_utf8(rest)

        {:utf16, endian, rest} ->
          Encoding.to_utf16(rest, endian)

        :none ->
          decode_unmarked(body, opts)
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

  # text/xml has no document charset here. Leave the bytes for the feed reader.
  # Treating them as UTF-8 first keeps a UTF-16 prefix and corrupts an address.
  defp decode_unmarked(body, opts) do
    case declared_charset(body, opts) do
      label when is_binary(label) -> decode_declared_charset(body, label, opts)
      _none -> decode_without_charset(body, opts)
    end
  end

  defp decode_without_charset(body, opts) do
    if MediaType.xml?(opts[:content_type]) do
      body
    else
      Encoding.decode_label(body, "utf-8")
    end
  end

  # "utf-16" does not say which byte order. Decoding it as big-endian drops a
  # little-endian address and destroys a UTF-8 body. The "<?xml" bytes decide.
  defp decode_declared_charset(body, "utf-16", opts) do
    if MediaType.xml?(opts[:content_type]) do
      utf16_xml(body) || body
    else
      Encoding.decode_label(body, "utf-16")
    end
  end

  defp decode_declared_charset(body, label, _opts) do
    Encoding.decode_label(body, label)
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
