defmodule Crawler.Charset.CSS do
  @moduledoc false

  alias Crawler.Analysis.Budget
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
    {:ok, decoded, _budget, _owned} = declare_result(body, Budget.unlimited(), :infinity, 0)
    decoded
  end

  def declare_result(body, budget, cap, owned) do
    scratch = 512 + min(byte_size(body), @prescan_bytes) * 32

    with {:ok, budget} <- Budget.reserve(budget, scratch) do
      case declaration(body) do
        {"utf-8", _rest} ->
          with {:ok, budget} <- Budget.release(budget, scratch), do: {:ok, body, budget, owned}

        {_label, rest} ->
          size = byte_size(~s(@charset "utf-8";)) + byte_size(rest)

          if cap != :infinity and size > cap do
            {:error, {:limit, :max_body}}
          else
            bytes = Budget.cost(:binary) + size

            with {:ok, budget} <- Budget.charge(budget, bytes) do
              decoded = IO.iodata_to_binary([~s(@charset "utf-8";), rest])

              with {:ok, budget} <- Budget.release(budget, scratch),
                   {:ok, budget} <- Budget.refund(budget, owned),
                   do: {:ok, decoded, budget, bytes}
            end
          end

        nil ->
          with {:ok, budget} <- Budget.release(budget, scratch), do: {:ok, body, budget, owned}
      end
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
