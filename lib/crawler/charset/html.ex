defmodule Crawler.Charset.HTML do
  @moduledoc false

  alias Crawler.Charset.Encoding
  alias Crawler.Charset.HTMLScanner
  alias Crawler.Charset.Labels
  alias Crawler.Charset.Parameters

  @prescan_bytes 1024

  def charset(body) do
    chunk =
      body
      |> binary_part(0, min(byte_size(body), @prescan_bytes))
      |> Labels.ascii_lower()

    chunk
    |> HTMLScanner.meta_spans()
    |> Enum.find_value(fn span ->
      label =
        chunk |> binary_part(elem(span, 0), elem(span, 1)) |> attrs_charset() |> meta_encoding()

      if Labels.known?(label), do: label
    end)
  end

  defp meta_encoding(label) do
    case Encoding.encoding(label) do
      {:utf16, _endian} -> "utf-8"
      _encoding -> label
    end
  end

  defp attrs_charset(tag) do
    attrs = HTMLScanner.attributes(tag)

    case Labels.normalize(attrs["charset"]) do
      label when is_binary(label) ->
        label

      _ ->
        if attrs["http-equiv"] == "content-type" do
          Labels.charset_param(";" <> (attrs["content"] || ""))
        end
    end
  end

  # The saved document is UTF-8. A meta that still names another encoding
  # would make a browser open a different path from the file that was fetched.
  def declare_utf8(body) do
    {parts, offset} =
      body
      |> HTMLScanner.meta_spans()
      |> Enum.reduce({[], 0}, fn {start, length}, {parts, offset} ->
        before_tag = binary_part(body, offset, start - offset)
        tag = binary_part(body, start, length)
        {[parts, before_tag, rewrite_tag(tag)], start + length}
      end)

    IO.iodata_to_binary([parts, binary_part(body, offset, byte_size(body) - offset)])
  end

  def xml_charset(body) do
    chunk = binary_part(body, 0, min(byte_size(body), @prescan_bytes))

    case xml_declaration(chunk) do
      {declaration, _rest} ->
        label =
          declaration |> HTMLScanner.attributes() |> Map.get("encoding") |> Labels.normalize()

        if Labels.known?(label), do: label

      nil ->
        nil
    end
  end

  def declare_xml_utf8(body) do
    case xml_declaration(body) do
      {declaration, rest} -> rewrite_xml_encoding(declaration) <> rest
      nil -> body
    end
  end

  defp xml_declaration(<<"<?xml", space, _rest::binary>> = body) when space in ~c" \t\n\r" do
    case :binary.match(body, "?>") do
      {finish, 2} ->
        size = finish + 2
        declaration = binary_part(body, 0, size)
        rest = binary_part(body, size, byte_size(body) - size)
        {declaration, rest}

      :nomatch ->
        nil
    end
  end

  defp xml_declaration(_body), do: nil

  defp rewrite_xml_encoding(declaration) do
    case HTMLScanner.find_attr_value(declaration, "encoding") do
      {start, finish} -> replace_label(declaration, start, finish)
      nil -> declaration
    end
  end

  defp rewrite_tag(tag) do
    tag = if content_type_meta?(tag), do: rewrite_content_charset(tag), else: tag
    rewrite_charset_attr(tag)
  end

  defp content_type_meta?(tag) do
    tag |> Labels.ascii_lower() |> HTMLScanner.attributes() |> Map.get("http-equiv") ==
      "content-type"
  end

  defp rewrite_charset_attr(tag) do
    case HTMLScanner.find_attr_value(Labels.ascii_lower(tag), "charset") do
      {start, finish} -> replace_label(tag, start, finish)
      _ -> tag
    end
  end

  defp rewrite_content_charset(tag) do
    case HTMLScanner.find_attr_value(Labels.ascii_lower(tag), "content") do
      nil ->
        tag

      {start, finish} ->
        value = binary_part(tag, start, finish - start)
        splice(tag, start, finish, rewrite_charset_param(value))
    end
  end

  defp rewrite_charset_param(value) do
    case Parameters.find_value(Labels.ascii_lower(value), "charset") do
      {start, finish} -> replace_label(value, start, finish)
      _ -> value
    end
  end

  defp replace_label(binary, start, finish), do: splice(binary, start, finish, "utf-8")

  defp splice(binary, start, finish, replacement) do
    head = binary_part(binary, 0, start)
    tail = binary_part(binary, finish, byte_size(binary) - finish)
    head <> replacement <> tail
  end
end
