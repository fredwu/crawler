defmodule Crawler.HTTP.DocumentHeaders do
  @moduledoc false

  def elements(headers) when is_list(headers) do
    refresh_elements(headers) ++ link_elements(headers)
  end

  def elements(_headers), do: []

  defp refresh_elements(headers) do
    headers
    |> values("refresh")
    |> Enum.reject(&blank?/1)
    |> Enum.map(fn value ->
      {"meta", [{"http-equiv", "refresh"}, {"content", value}], []}
    end)
  end

  defp link_elements(headers) do
    headers
    |> values("link")
    |> Enum.flat_map(&split_outside(&1, ?,))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&link_element/1)
  end

  defp link_element(value) do
    case uri_and_params(value) do
      {url, params} -> params |> link_params() |> link_element(url)
      :error -> []
    end
  end

  defp link_element(%{"rel" => rel} = attrs, url) when is_binary(rel) do
    [{"link", link_attributes(rel, url, attrs), []}]
  end

  defp link_element(_attrs, _url), do: []

  defp link_attributes(rel, url, attrs) do
    [{"rel", rel}, {"href", url}]
    |> param("as", attrs)
    |> param("imagesrcset", attrs)
  end

  defp param(attributes, name, attrs) do
    case attrs[name] do
      value when is_binary(value) -> attributes ++ [{name, value}]
      _other -> attributes
    end
  end

  defp link_params(params) do
    params
    |> split_outside(?;)
    |> Enum.reduce(%{}, &put_param/2)
  end

  defp put_param(param, acc) do
    case param_pair(param) do
      {name, value} -> Map.put_new(acc, name, value)
      _other -> acc
    end
  end

  defp param_pair(param) do
    case String.split(String.trim(param), "=", parts: 2) do
      [name, value] ->
        name
        |> String.trim()
        |> String.downcase(:ascii)
        |> named_param(decode_param(value))

      _other ->
        nil
    end
  end

  defp named_param(_name, nil), do: nil
  defp named_param("rel", value), do: {"rel", value}
  defp named_param("as", value), do: {"as", value}
  defp named_param("imagesrcset", value), do: {"imagesrcset", value}
  defp named_param(_name, _value), do: nil

  defp uri_and_params(<<"<", rest::binary>>) do
    case :binary.split(rest, ">") do
      [url, params] -> {url, params}
      _ -> :error
    end
  end

  defp uri_and_params(_value), do: :error

  defp decode_param(value) do
    value = value |> String.trim() |> unescape_quoted()
    if value == "", do: nil, else: value
  end

  defp unescape_quoted(<<?", rest::binary>>) do
    String.trim_trailing(rest, "\"")
  end

  defp unescape_quoted(value), do: value

  defp values(headers, name) do
    Enum.flat_map(headers, fn
      {key, value} when is_binary(value) ->
        if header_name?(key, name), do: [value], else: []

      _other ->
        []
    end)
  end

  defp header_name?(key, name) do
    key |> to_string() |> String.downcase() == name
  end

  defp blank?(value), do: String.trim(value) == ""

  defp split_outside(value, separator) do
    value
    |> split_outside(separator, <<>>, [], false, 0)
    |> Enum.reverse()
  end

  defp split_outside(<<>>, _separator, current, acc, _quoted, _angles) do
    [current | acc]
  end

  defp split_outside(<<?\\, char, rest::binary>>, separator, current, acc, true, angles) do
    split_outside(rest, separator, <<current::binary, char>>, acc, true, angles)
  end

  defp split_outside(<<?", rest::binary>>, separator, current, acc, quoted, 0) do
    split_outside(rest, separator, <<current::binary, ?">>, acc, not quoted, 0)
  end

  defp split_outside(<<?<, rest::binary>>, separator, current, acc, false, angles) do
    split_outside(rest, separator, <<current::binary, ?<>>, acc, false, angles + 1)
  end

  defp split_outside(<<?>, rest::binary>>, separator, current, acc, false, angles)
       when angles > 0 do
    split_outside(rest, separator, <<current::binary, ?>>>, acc, false, angles - 1)
  end

  defp split_outside(<<separator, rest::binary>>, separator, current, acc, false, 0) do
    split_outside(rest, separator, <<>>, [current | acc], false, 0)
  end

  defp split_outside(<<char, rest::binary>>, separator, current, acc, quoted, angles) do
    split_outside(rest, separator, <<current::binary, char>>, acc, quoted, angles)
  end
end
