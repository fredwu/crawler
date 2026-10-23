defmodule Crawler.URL do
  @moduledoc false

  alias Crawler.Analysis.Budget
  alias Crawler.URL.Authority
  alias Crawler.URL.Percent

  @schemes ["http", "https"]

  def normalize(url) when is_binary(url) do
    case prepare(url) do
      {:http, uri} -> uri |> fold_uri() |> URI.to_string()
      {:plain, plain} -> plain_normalize(plain)
      {:invalid, invalid} -> invalid
    end
  end

  @doc false
  def canonical(url) when is_binary(url) do
    case prepare(url) do
      {:http, uri} ->
        # The store key aliases a single optional trailing slash and drops the
        # fragment. Repeated trailing slashes remain distinct path segments.
        uri
        |> fold_uri()
        |> URI.to_string()
        |> strip_trailing_slash()

      {:plain, plain} ->
        plain_canonical(plain)

      {:invalid, invalid} ->
        invalid
    end
  end

  def resolve(link, base) do
    case resolve_result(link, base, Budget.unlimited()) do
      {:ok, url, _budget} -> {:ok, url}
      {:skip, _budget} -> :skip
    end
  end

  @doc false
  def resolve_result(link, base, budget) when is_binary(link) do
    bytes = byte_size(link) + binary_size(base)

    # Includes simultaneous URI captures, percent buffers, path segment lists,
    # reversals and merge buffers. A percent fold grows each input byte at most
    # threefold; lists use at most one segment or byte entry per input byte.
    scratch = 4_096 + 2_048 * (bytes + 1)
    with_scratch(budget, scratch, &resolve_reserved(link, base, &1))
  end

  def resolve_result(_link, _base, budget), do: {:skip, budget}

  defp resolve_reserved(link, base, budget) do
    link = sanitize(link)

    link =
      if is_binary(base) and http_scheme?(sanitize(base)),
        do: slash_before_query(link),
        else: link

    if link == "" do
      {:skip, budget}
    else
      case reference(link, budget) do
        {:ok, reference, budget} -> resolve_reference(reference, base, budget)
        {:invalid, budget} -> {:skip, budget}
        {:error, _reason} = error -> error
      end
    end
  end

  defp http_uri(url, budget) do
    case URI.parse(url) do
      %URI{scheme: scheme} = uri when scheme in @schemes ->
        Authority.parse_result(url, uri, budget)

      _ ->
        {:invalid, budget}
    end
  end

  defp prepare(url) do
    case prepare_result(url, Budget.unlimited()) do
      {:http, uri, _budget} -> {:http, uri}
      {:plain, plain, _budget} -> {:plain, plain}
      {:invalid, invalid, _budget} -> {:invalid, invalid}
    end
  end

  defp prepare_result(url, budget) do
    trimmed = url |> strip_breaks() |> trim_c0()

    if http_scheme?(trimmed) do
      case http_uri(slash_before_query(trimmed), budget) do
        {:ok, uri, budget} -> {:http, uri, budget}
        {:invalid, budget} -> {:invalid, trimmed, budget}
        {:error, _reason} = error -> error
      end
    else
      {:plain, trimmed, budget}
    end
  end

  @doc false
  def sanitize(url) when is_binary(url) do
    trimmed = url |> strip_breaks() |> trim_c0()
    if http_scheme?(trimmed), do: slash_before_query(trimmed), else: trimmed
  end

  defp fold_uri(%URI{} = uri) do
    drop_default_port(%{
      uri
      | scheme: String.downcase(uri.scheme),
        userinfo: fold_userinfo(uri.userinfo),
        path: fold_path(uri.path),
        query: fold_query(uri.query),
        fragment: nil
    })
  end

  # Letter case stays a different page. `@` and other userinfo delimiters are encoded.
  defp fold_userinfo(nil), do: nil
  defp fold_userinfo(userinfo), do: Percent.userinfo(userinfo)

  defp fold_path(nil), do: nil

  defp fold_path(path) do
    path |> canonicalize_path() |> remove_dot_segments()
  end

  defp canonicalize_path(nil), do: nil

  defp canonicalize_path(path) do
    path
    |> :binary.replace("\\", "/", [:global])
    |> Percent.canonicalize(:path)
    |> decode_dot_segments()
  end

  # `%2e` stays inside a longer segment. A segment that is only a dot is `.`
  # or `..` before merge, so a relative parent still climbs out of the base.
  defp decode_dot_segments(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &dot_segment/1)
  end

  defp dot_segment("%2e"), do: "."
  defp dot_segment("%2e."), do: ".."
  defp dot_segment(".%2e"), do: ".."
  defp dot_segment("%2e%2e"), do: ".."
  defp dot_segment(segment), do: segment

  defp fold_query(nil), do: nil
  defp fold_query(query), do: Percent.canonicalize(query, :query)

  defp plain_normalize(url) do
    url
    |> URI.parse()
    |> Map.put(:fragment, nil)
    |> drop_default_port()
    |> URI.to_string()
  end

  defp plain_canonical(url) do
    {base, _fragment} = split_piece(url, "#")
    {path, query} = split_piece(base, "?")
    trim_optional_slash(path) <> query_part(query)
  end

  defp query_part(nil), do: ""
  defp query_part(query), do: "?" <> query

  defp strip_trailing_slash(url) do
    {base, query} =
      case String.split(url, "?", parts: 2) do
        [base, query] -> {base, "?" <> query}
        [base] -> {base, ""}
      end

    trim_optional_slash(base) <> query
  end

  # Drop a segment that is only `.` or `..`. `canonicalize_path/1` already
  # rewrote a whole-segment `%2e` into those spellings. `...` and `foo%2ehtml`
  # stay. `%2F` is one segment, not a slash.
  defp remove_dot_segments(path) when is_binary(path) do
    absolute? = String.starts_with?(path, "/")

    path
    |> path_segments(absolute?)
    |> Enum.reduce([], &push_segment/2)
    |> finish_dot_segment(final_dot_segment?(path))
    |> Enum.reverse()
    |> format_path(absolute?)
  end

  defp path_segments(path, absolute?) do
    path |> drop_one_leading_slash(absolute?) |> String.split("/")
  end

  defp finish_dot_segment(segments, true), do: ["" | segments]
  defp finish_dot_segment(segments, false), do: segments

  defp drop_one_leading_slash("/" <> rest, true), do: rest
  defp drop_one_leading_slash(path, _absolute?), do: path

  defp final_dot_segment?(path) do
    path |> String.split("/") |> List.last() |> segment_kind() != :segment
  end

  defp push_segment(segment, acc) do
    case segment_kind(segment) do
      :dot -> acc
      :dot_dot -> drop_segment(acc)
      :segment -> [segment | acc]
    end
  end

  defp drop_segment([]), do: []
  defp drop_segment([_segment | acc]), do: acc

  defp segment_kind("."), do: :dot
  defp segment_kind(".."), do: :dot_dot
  defp segment_kind(_segment), do: :segment

  defp format_path(segments, absolute?) do
    body = Enum.join(segments, "/")
    if absolute?, do: "/" <> body, else: body
  end

  defp reference(link, budget) do
    uri = URI.parse(link)

    cond do
      is_binary(uri.scheme) and uri.scheme not in @schemes ->
        {:invalid, budget}

      uri.scheme in @schemes or String.starts_with?(link, "//") ->
        Authority.parse_result(link, uri, budget)

      true ->
        {:ok, uri, budget}
    end
  end

  defp resolve_reference(%URI{scheme: scheme} = reference, _base, budget)
       when scheme in @schemes do
    crawlable(reference, budget)
  end

  defp resolve_reference(reference, base, budget) when is_binary(base) and base != "" do
    case prepare_result(base, budget) do
      {:http, uri, budget} ->
        reference = %{reference | path: canonicalize_path(reference.path)}
        uri = fold_uri(uri)
        bytes = binary_size(uri.path) + binary_size(reference.path)
        scratch = Budget.cost(:binary) + 512 * (bytes + 1)

        with_scratch(budget, scratch, fn budget ->
          uri |> URI.merge(reference) |> crawlable(budget)
        end)

      {:error, _reason} = error ->
        error

      {_kind, _value, budget} ->
        {:skip, budget}
    end
  end

  defp resolve_reference(reference, _base, budget), do: crawlable(reference, budget)

  defp crawlable(%URI{scheme: scheme} = uri, budget) when scheme in @schemes do
    uri = fold_uri(uri)
    capacity = formatted_capacity(uri) + Budget.cost(:binary)

    with {:ok, budget} <- Budget.reserve(budget, capacity),
         url = URI.to_string(uri),
         {:ok, budget} <- Budget.settle(budget, capacity, byte_size(url) + Budget.cost(:binary)) do
      {:ok, url, budget}
    end
  end

  defp crawlable(_uri, budget), do: {:skip, budget}

  # Delimiters, IPv6 brackets and a validated decimal port fit in 32 bytes.
  defp formatted_capacity(uri) do
    32 + binary_size(uri.scheme) + binary_size(uri.userinfo) + binary_size(uri.host) +
      binary_size(uri.path) + binary_size(uri.query)
  end

  defp binary_size(value) when is_binary(value), do: byte_size(value)
  defp binary_size(_value), do: 0

  defp with_scratch(budget, bytes, fun) do
    with {:ok, reserved} <- Budget.reserve(budget, bytes) do
      case fun.(reserved) do
        {:ok, value, budget} ->
          with {:ok, budget} <- Budget.release(budget, bytes), do: {:ok, value, budget}

        {:skip, budget} ->
          with {:ok, budget} <- Budget.release(budget, bytes), do: {:skip, budget}

        {:error, _reason} = error ->
          {:ok, _released} = Budget.release(reserved, bytes)
          error
      end
    end
  end

  defp drop_default_port(%URI{scheme: "http", port: 80} = uri), do: %{uri | port: nil}
  defp drop_default_port(%URI{scheme: "https", port: 443} = uri), do: %{uri | port: nil}
  defp drop_default_port(uri), do: uri

  defp strip_breaks(url), do: strip_bytes(url, [?\t, ?\n, ?\r], [])

  defp strip_bytes(<<byte, rest::binary>>, dropped, acc) do
    acc = if byte in dropped, do: acc, else: [acc, byte]
    strip_bytes(rest, dropped, acc)
  end

  defp strip_bytes(<<>>, _dropped, acc), do: IO.iodata_to_binary(acc)

  defp trim_c0(url) do
    url
    |> trim_leading_c0()
    |> trim_trailing_c0()
  end

  defp trim_leading_c0(<<byte, rest::binary>>) when byte <= 0x20, do: trim_leading_c0(rest)
  defp trim_leading_c0(url), do: url

  defp trim_trailing_c0(url) do
    size = byte_size(url)

    if size > 0 and :binary.at(url, size - 1) <= 0x20 do
      url
      |> binary_part(0, size - 1)
      |> trim_trailing_c0()
    else
      url
    end
  end

  defp http_scheme?(url) do
    size = min(byte_size(url), 6)
    prefix = ascii_lower(binary_part(url, 0, size))
    String.starts_with?(prefix, "http:") or String.starts_with?(prefix, "https:")
  end

  defp ascii_lower(binary) do
    for <<byte <- binary>>, into: <<>> do
      if byte in ?A..?Z, do: <<byte + 32>>, else: <<byte>>
    end
  end

  defp slash_before_query(url) do
    {before_hash, hash} = split_piece(url, "#")
    {before_query, query} = split_piece(before_hash, "?")
    slashed = :binary.replace(before_query, "\\", "/", [:global])
    reassemble(slashed, query, hash)
  end

  defp split_piece(text, separator) do
    case :binary.split(text, separator) do
      [left, right] -> {left, right}
      [left] -> {left, nil}
    end
  end

  defp reassemble(base, query, fragment) do
    base
    |> append_piece("?", query)
    |> append_piece("#", fragment)
  end

  defp append_piece(url, _mark, nil), do: url
  defp append_piece(url, mark, value), do: url <> mark <> value

  defp trim_optional_slash(path) do
    if String.ends_with?(path, "/") and not String.ends_with?(path, "//") do
      String.replace_suffix(path, "/", "")
    else
      path
    end
  end
end
