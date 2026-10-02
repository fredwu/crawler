defmodule Crawler.Charset.CSS do
  @moduledoc false

  alias Crawler.Charset.Encoding
  alias Crawler.Charset.Labels

  @prefix ~s(@charset ")
  @suffix ~s(";)
  @prescan_bytes 1024

  def charset(body) do
    case declaration(body) do
      {label, _rest} -> declared_label(label)
      nil -> nil
    end
  end

  def declare_utf8(body) do
    case declaration(body) do
      {_label, rest} -> ~s(@charset "utf-8";) <> rest
      nil -> body
    end
  end

  defp declared_label(value) do
    label = Labels.normalize(value)

    case Encoding.encoding(label) do
      {:utf16, _endian} -> "utf-8"
      :unknown -> nil
      _encoding -> label
    end
  end

  defp declaration(<<@prefix, rest::binary>>) do
    scan = binary_part(rest, 0, min(byte_size(rest), @prescan_bytes - byte_size(@prefix)))

    case :binary.match(scan, @suffix) do
      {size, suffix_size} ->
        label = binary_part(rest, 0, size)
        offset = size + suffix_size

        if ascii_label?(label) do
          {label, binary_part(rest, offset, byte_size(rest) - offset)}
        end

      :nomatch ->
        nil
    end
  end

  defp declaration(_body), do: nil

  defp ascii_label?(label) do
    label |> :binary.bin_to_list() |> Enum.all?(&(&1 <= 0x7F and &1 != ?"))
  end
end
