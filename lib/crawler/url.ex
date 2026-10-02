defmodule Crawler.URL do
  @moduledoc false

  alias Crawler.URL.Host
  alias Crawler.URL.Percent

  @schemes ["http", "https"]

  def normalize(url) when is_binary(url) do
    case prepare(url) do
      {:http, uri} -> uri |> fold_uri() |> URI.to_string()
      {:plain, plain} -> plain_normalize(plain)
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
    end
  end

  def resolve(link, base) when is_binary(link) do
    # Scheme checks must see the same spelling normalize/1 fetches. A tab,
    # break, or path backslash is removed before this link is classified.
    link = sanitize(link)

    cond do
      link == "" ->
        :skip

      disallowed?(link) ->
        :skip

      true ->
        link
        |> merge(base)
        |> crawlable()
    end
  end

  def resolve(_link, _base), do: :skip

  defp http_uri(url) do
    uri = URI.parse(url)

    if uri.scheme in @schemes and is_binary(uri.host) and uri.host != "" do
      {:ok, uri}
    else
      :plain
    end
  end

  defp prepare(url) do
    trimmed = url |> strip_breaks() |> trim_c0()

    if http_scheme?(trimmed) do
      case http_uri(slash_before_query(trimmed)) do
        {:ok, uri} -> {:http, uri}
        :plain -> {:plain, trimmed}
      end
    else
      {:plain, trimmed}
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
        host: Host.fold(uri.host),
        path: fold_path(uri.path),
        query: fold_query(uri.query),
        fragment: nil
    })
  end

  # Userinfo case is a different page. Only the hex digits inside `%HH` fold.
  defp fold_userinfo(nil), do: nil
  defp fold_userinfo(userinfo), do: Percent.lowercase_hex(userinfo)

  defp fold_path(nil), do: nil

  defp fold_path(path) do
    path
    |> :binary.replace("\\", "/", [:global])
    |> Percent.canonicalize()
    |> remove_dot_segments()
  end

  defp fold_query(nil), do: nil
  defp fold_query(query), do: Percent.canonicalize(query)

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

  # Drop `.` and `..`, including a dot that was written as `%2e`. `...` stays a
  # segment. `%2F` is one segment, not a slash.
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
    path in [".", ".."] or String.ends_with?(path, "/.") or String.ends_with?(path, "/..")
  end

  defp push_segment(".", acc), do: acc
  defp push_segment("..", []), do: []
  defp push_segment("..", [_segment | acc]), do: acc
  defp push_segment(segment, acc), do: [segment | acc]

  defp format_path(segments, absolute?) do
    body = Enum.join(segments, "/")
    if absolute?, do: "/" <> body, else: body
  end

  defp disallowed?(link) do
    case URI.parse(link) do
      %URI{scheme: scheme} when is_binary(scheme) and scheme not in @schemes -> true
      _ -> false
    end
  end

  defp merge(link, base) do
    cond do
      scheme_absolute?(link) ->
        URI.parse(link)

      is_binary(base) and base != "" ->
        # Fold a dot segment in the base before merging. Elixir otherwise
        # leaves a "+" when the base path ends in `.` or `..`.
        URI.merge(merge_base(base), link)

      true ->
        URI.parse(link)
    end
  end

  defp merge_base(base) do
    case http_uri(base) do
      {:ok, _uri} -> normalize(base)
      :plain -> base
    end
  end

  defp scheme_absolute?(link) do
    case URI.parse(link) do
      %URI{scheme: scheme, host: host} when scheme in @schemes and is_binary(host) -> true
      _ -> false
    end
  end

  defp crawlable(%URI{scheme: scheme, host: host} = uri)
       when scheme in @schemes and is_binary(host) do
    {:ok, normalize(URI.to_string(%{uri | fragment: nil}))}
  end

  defp crawlable(_uri), do: :skip

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
