defmodule Crawler.Charset.HTML do
  @moduledoc false

  alias Crawler.Analysis.Budget
  alias Crawler.Charset.Encoding
  alias Crawler.Charset.HTMLScanner
  alias Crawler.Charset.Labels
  alias Crawler.Charset.Parameters
  alias Crawler.HTMLSpans

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
    {:ok, decoded, _budget, _owned} = declare_result(body, Budget.unlimited(), :infinity, 0)
    decoded
  end

  def declare_result(body, budget, cap, owned) do
    scratch = Budget.cost(:frame)

    with {:ok, budget} <- Budget.reserve(budget, scratch) do
      acc = %{edits: [], count: 0, bytes: 0, size: byte_size(body), cap: cap}

      with {:ok, acc, budget} <-
             HTMLSpans.reduce_tags_result(body, [attributes: false], budget, acc, &rewrite_meta/3),
           {:ok, decoded, budget, owned} <- apply_edits(body, acc, budget, owned),
           {:ok, budget} <- Budget.release(budget, scratch),
           do: {:ok, decoded, budget, owned}
    end
  end

  defp rewrite_meta(%{name: "meta", closing?: false} = tag, acc, budget) do
    scratch = 4_096 + byte_size(tag.source) * 512

    with {:ok, budget} <- Budget.reserve(budget, scratch) do
      rewritten = :binary.copy(rewrite_tag(tag.source))

      if rewritten == tag.source do
        with {:ok, budget} <- Budget.release(budget, scratch), do: {:cont, acc, budget}
      else
        {start, length} = tag.span
        size = acc.size + byte_size(rewritten) - length
        bytes = Budget.cost(:edit) + :binary.referenced_byte_size(rewritten)

        with {:ok, budget} <- Budget.settle(budget, scratch, bytes) do
          acc = %{
            acc
            | edits: [{start, length, rewritten} | acc.edits],
              count: acc.count + 1,
              bytes: acc.bytes + bytes,
              size: size
          }

          {:cont, acc, budget}
        end
      end
    end
  end

  defp rewrite_meta(_tag, acc, budget), do: {:cont, acc, budget}

  defp apply_edits(_body, %{size: size, cap: cap}, _budget, _owned)
       when is_integer(cap) and size > cap,
       do: {:error, {:limit, :max_body}}

  defp apply_edits(body, %{edits: []}, budget, owned), do: {:ok, body, budget, owned}

  defp apply_edits(body, acc, budget, owned) do
    retained = Budget.cost(:binary) + acc.size

    scratch =
      retained + acc.count * (Budget.cost(:list_cell, 4) + Budget.cost(:binary, 2)) +
        Budget.cost(:binary, 2)

    with {:ok, budget} <- Budget.reserve(budget, scratch) do
      {parts, offset} =
        acc.edits
        |> Enum.reverse()
        |> Enum.reduce({[], 0}, fn {start, length, replacement}, {parts, offset} ->
          before = binary_part(body, offset, start - offset)
          {[parts, before, replacement], start + length}
        end)

      decoded = IO.iodata_to_binary([parts, binary_part(body, offset, byte_size(body) - offset)])

      with {:ok, budget} <- Budget.settle(budget, scratch, retained),
           {:ok, budget} <- Budget.refund(budget, owned + acc.bytes),
           do: {:ok, decoded, budget, retained}
    end
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
    {:ok, decoded, _budget, _owned} = declare_xml_result(body, Budget.unlimited(), :infinity, 0)
    decoded
  end

  def declare_xml_result(body, budget, cap, owned) do
    with {:ok, budget} <- Budget.reserve(budget, Budget.cost(:frame)) do
      case xml_declaration(body) do
        {declaration, rest} ->
          rewrite_xml_declaration(body, declaration, rest, budget, cap, owned)

        nil ->
          with {:ok, budget} <- Budget.release(budget, Budget.cost(:frame)),
               do: {:ok, body, budget, owned}
      end
    end
  end

  defp rewrite_xml_declaration(body, declaration, rest, budget, cap, owned) do
    scratch = 4_096 + byte_size(declaration) * 512

    with {:ok, budget} <- Budget.reserve(budget, scratch) do
      rewritten = :binary.copy(rewrite_xml_encoding(declaration))

      if rewritten == declaration do
        with {:ok, budget} <- Budget.release(budget, scratch + Budget.cost(:frame)),
             do: {:ok, body, budget, owned}
      else
        size = byte_size(rewritten) + byte_size(rest)

        if cap != :infinity and size > cap do
          {:error, {:limit, :max_body}}
        else
          bytes = Budget.cost(:binary) + size

          with {:ok, budget} <- Budget.charge(budget, bytes) do
            decoded = IO.iodata_to_binary([rewritten, rest])

            with {:ok, budget} <- Budget.release(budget, scratch + Budget.cost(:frame)),
                 {:ok, budget} <- Budget.refund(budget, owned),
                 do: {:ok, decoded, budget, bytes}
          end
        end
      end
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
