defmodule Crawler.Charset do
  @moduledoc false

  alias Crawler.Analysis.Budget
  alias Crawler.Charset.CSS
  alias Crawler.Charset.Encoding
  alias Crawler.Charset.HTML
  alias Crawler.Charset.Labels
  alias Crawler.MediaType

  def decode(body, opts) do
    {:ok, decoded, _budget, _ownership} = decode_owned(body, opts, Budget.unlimited(), :infinity)
    decoded
  end

  def decode_result(body, opts, budget) do
    with {:ok, decoded, budget, _ownership} <- decode_owned_result(body, opts, budget),
         do: {:ok, decoded, budget}
  end

  def decode_owned_result(body, opts, budget) do
    cap =
      case opts[:max_body] do
        nil -> :infinity
        cap -> cap
      end

    if cap == :infinity or (is_integer(cap) and cap >= 0),
      do: decode_owned(body, opts, budget, cap),
      else: {:error, :invalid_limits}
  end

  defp decode_owned("", _opts, budget, _cap), do: {:ok, "", budget, :borrowed}

  defp decode_owned(body, opts, budget, cap) when is_binary(body) do
    type = opts[:content_type]
    scratch = Budget.cost(:frame, 2) + if(is_binary(type), do: byte_size(type) * 16, else: 0)

    with {:ok, budget} <- Budget.reserve(budget, scratch) do
      result =
        if textual?(type),
          do: transcode(body, opts, budget, cap),
          else: {:ok, body, budget, 0, :borrowed}

      with {:ok, decoded, budget, _owned, ownership} <- result,
           :ok <- output_limit(decoded, cap),
           {:ok, budget} <- Budget.release(budget, scratch),
           do: {:ok, decoded, budget, ownership}
    end
  end

  defp decode_owned(body, _opts, budget, _cap), do: {:ok, body, budget, :borrowed}

  def utf16_xml(body) do
    case utf16_endian(body) do
      nil -> nil
      endian -> Encoding.to_utf16(body, endian)
    end
  end

  # The existing XML prefix is the only BOM-less UTF-16 byte-order sniff.
  defp utf16_endian(<<0x3C, 0x00, 0x3F, 0x00, 0x78, 0x00, 0x6D, 0x00, 0x6C, 0x00, _::binary>>),
    do: :little

  defp utf16_endian(<<0x00, 0x3C, 0x00, 0x3F, 0x00, 0x78, 0x00, 0x6D, 0x00, 0x6C, _::binary>>),
    do: :big

  defp utf16_endian(_body), do: nil

  defp textual?(type) do
    MediaType.text?(type) or MediaType.javascript?(type) or xml_document?(type)
  end

  defp transcode(body, opts, budget, cap) do
    converted =
      case Encoding.bom(body) do
        {:utf8, rest} ->
          convert_view(rest, :utf8, budget)

        {:utf16, endian, rest} ->
          convert_view(rest, {:utf16, endian}, budget)

        :none ->
          with {:ok, recipe, budget} <- recipe(body, opts, budget),
               do: convert(body, recipe, budget, 0, :borrowed)
      end

    with {:ok, converted, budget, owned, ownership} <- converted do
      declaration =
        cond do
          xml_document?(opts[:content_type]) ->
            HTML.declare_xml_result(converted, budget, cap, owned)

          MediaType.html?(opts[:content_type]) ->
            HTML.declare_result(converted, budget, cap, owned)

          MediaType.css?(opts[:content_type]) ->
            CSS.declare_result(converted, budget, cap, owned)

          true ->
            {:ok, converted, budget, owned}
        end

      with {:ok, decoded, budget, owned} <- declaration do
        ownership = if :erts_debug.same(decoded, converted), do: ownership, else: :retained
        {:ok, decoded, budget, owned, ownership}
      end
    end
  end

  defp convert_view(body, recipe, budget) do
    # A slice of the borrowed input may share its backing, or be a small copied binary.
    owned =
      if body == "",
        do: 0,
        else:
          Budget.cost(:binary) +
            if(:binary.referenced_byte_size(body) > byte_size(body), do: 0, else: byte_size(body))

    ownership =
      if body == "" or :binary.referenced_byte_size(body) > byte_size(body),
        do: :borrowed,
        else: :retained

    with {:ok, budget} <- Budget.charge(budget, owned),
         do: convert(body, recipe, budget, owned, ownership)
  end

  defp convert(body, :keep, budget, owned, ownership),
    do: {:ok, body, budget, owned, ownership}

  defp convert(body, recipe, budget, previous, ownership) do
    with {:ok, decoded, budget, owned} <- Encoding.decode_result(body, recipe, budget) do
      if owned == 0 do
        {:ok, decoded, budget, previous, ownership}
      else
        with {:ok, budget} <- Budget.refund(budget, previous),
             do: {:ok, decoded, budget, owned, :retained}
      end
    end
  end

  defp output_limit(body, cap) do
    if cap == :infinity or byte_size(body) <= cap, do: :ok, else: {:error, {:limit, :max_body}}
  end

  defp recipe(body, opts, budget) do
    with {:ok, label, budget} <- Labels.http_charset_result(opts[:headers], budget) do
      if is_binary(label) do
        recipe = declared_recipe(body, label, opts)

        with {:ok, budget} <- Budget.refund(budget, Budget.cost(:binary) + byte_size(label)),
             do: {:ok, recipe, budget}
      else
        document_recipe(body, opts, budget)
      end
    end
  end

  defp document_recipe(body, opts, budget) do
    type = opts[:content_type]

    if xml_document?(type) or MediaType.html?(type) or MediaType.css?(type) do
      scratch = 2_048 + min(byte_size(body), 1_024) * 512

      with {:ok, budget} <- Budget.reserve(budget, scratch) do
        recipe =
          case document_charset(body, type) do
            label when is_binary(label) -> declared_recipe(body, label, opts)
            _none -> default_recipe(body, opts)
          end

        with {:ok, budget} <- Budget.release(budget, scratch), do: {:ok, recipe, budget}
      end
    else
      {:ok, default_recipe(body, opts), budget}
    end
  end

  defp default_recipe(body, opts) do
    cond do
      MediaType.xml?(opts[:content_type]) -> utf16_recipe(body, :keep)
      xml_document?(opts[:content_type]) -> utf16_recipe(body, :utf8)
      true -> :utf8
    end
  end

  defp declared_recipe(body, "utf-16", opts) do
    if MediaType.xml?(opts[:content_type]) or xml_document?(opts[:content_type]),
      do: utf16_recipe(body, :keep),
      else: {:utf16, :big}
  end

  defp declared_recipe(_body, label, _opts), do: Encoding.encoding(label)

  defp utf16_recipe(body, fallback) do
    case utf16_endian(body) do
      nil -> fallback
      endian -> {:utf16, endian}
    end
  end

  defp document_charset(body, type) do
    cond do
      xml_document?(type) -> HTML.xml_charset(body)
      MediaType.html?(type) -> HTML.charset(body)
      MediaType.css?(type) -> CSS.charset(body)
      true -> nil
    end
  end

  defp xml_document?(type), do: MediaType.document_mode(type) == :xml
end
