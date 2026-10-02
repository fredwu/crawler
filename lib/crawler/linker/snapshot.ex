defmodule Crawler.Linker.Snapshot do
  @moduledoc """
  Builds offline filesystem paths and URL references to the saved files.
  """

  alias Crawler.Linker.PathOffliner
  alias Crawler.Linker.Snapshot.Component
  alias Crawler.URL

  @port_marker "__port_"
  @colon_marker "__c_"
  @empty_marker "__e_"
  @user_marker "__user_"
  @scheme_marker "__scheme_"
  @case_marker "__u_"
  @mark_marker "__m_"
  @jamo_marker "__j_"
  @extension_marker "__ext_"
  @directory_marker "__dir_"
  @combining_mark ~r/\p{M}/u
  # Longer markers stay ahead of their prefixes. `__u_` is a prefix of `__user_`.
  @markers [
    @empty_marker,
    @port_marker,
    @colon_marker,
    @user_marker,
    @scheme_marker,
    @case_marker,
    @mark_marker,
    @jamo_marker,
    @extension_marker,
    @directory_marker,
    Component.marker()
  ]

  def path(url) when is_binary(url) do
    case URI.parse(URL.normalize(url)) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        uri
        |> logical_path()
        |> PathOffliner.transform()
        |> encode_segments()
        |> decorate_host(uri)
        |> encode_file_identity()
        |> Component.bound()

      _ ->
        url
    end
  end

  def relative(from_url, to_url) when is_binary(from_url) and is_binary(to_url) do
    directory = from_url |> path() |> drop_last_segment()
    depth = directory |> String.split("/", trim: true) |> length()

    String.duplicate("../", depth) <> url_path(to_url)
  end

  @doc "Encodes a filesystem path as a URL path, preserving directory separators."
  def url_path(url) when is_binary(url) do
    url
    |> path()
    |> URI.encode(fn byte -> byte == ?/ or URI.char_unreserved?(byte) end)
  end

  defp logical_path(%URI{host: host, path: path, query: query}) do
    base = Enum.join([host | path_segments(path)], "/")

    # `nil` is "no query". An empty string is the bare "?" and must survive.
    case query do
      nil -> base
      query -> base <> "?" <> query
    end
  end

  defp path_segments(nil), do: []

  defp path_segments(path) do
    path =
      path
      |> drop_optional_trailing_slash()
      |> drop_one_leading_slash()

    if path == "", do: [], else: String.split(path, "/")
  end

  defp drop_one_leading_slash("/" <> rest), do: rest
  defp drop_one_leading_slash(path), do: path

  defp drop_optional_trailing_slash(path) do
    if String.ends_with?(path, "//"), do: path, else: String.trim_trailing(path, "/")
  end

  defp drop_last_segment(path) do
    path
    |> String.split("/")
    |> Enum.drop(-1)
    |> Enum.join("/")
  end

  # `%` is already escaped by PathOffliner, so a marker's `%5f` is not encoded
  # again. The hex digit is lowercase so later case encoding leaves it alone.
  # Empty segments would otherwise collapse to the same file as a path
  # without them. Host suffixes are added after this step.
  defp encode_segments(path) do
    segments = String.split(path, "/")
    last = length(segments) - 1

    segments
    |> Enum.with_index()
    |> Enum.map_join("/", fn {segment, index} ->
      encoded = encode_segment(segment)

      if index > 0 and index < last and PathOffliner.resource_filename?(segment) do
        @directory_marker <> encoded
      else
        encoded
      end
    end)
  end

  defp encode_segment(""), do: @empty_marker

  defp encode_segment(segment) do
    segment
    |> escape_markers()
    |> String.replace(":", @colon_marker)
  end

  # http keeps the plain host so existing archive paths stay stable. https,
  # a username, and a non-default port are suffixes on that host. They are
  # different pages and must not overwrite one file.
  defp decorate_host(path, %URI{} = uri) do
    path
    |> append_host(userinfo_suffix(uri.userinfo))
    |> append_host(port_suffix(explicit_port(uri)))
    |> append_host(scheme_suffix(uri.scheme))
  end

  defp userinfo_suffix(info) when is_binary(info) and info != "" do
    @user_marker <> encode_userinfo(info)
  end

  defp userinfo_suffix(_info), do: nil

  defp port_suffix(nil), do: nil
  defp port_suffix(port), do: @port_marker <> Integer.to_string(port)

  defp scheme_suffix("https"), do: @scheme_marker <> "https"
  defp scheme_suffix(_scheme), do: nil

  defp explicit_port(%URI{scheme: "http", port: 80}), do: nil
  defp explicit_port(%URI{scheme: "https", port: 443}), do: nil
  defp explicit_port(%URI{port: port}) when is_integer(port), do: port
  defp explicit_port(_uri), do: nil

  defp append_host(path, nil), do: path

  defp append_host(path, suffix) do
    case String.split(path, "/", parts: 2) do
      [host, rest] -> host <> suffix <> "/" <> rest
      [host] -> host <> suffix
    end
  end

  # Userinfo is appended after segment encoding, so it has to escape its own
  # markers. `%` introduced here is not encoded a second time.
  defp encode_userinfo(info) do
    info
    |> percent_encode_reserved()
    |> escape_markers()
  end

  defp percent_encode_reserved(text) do
    for <<byte <- text>>, into: "" do
      if reserved_byte?(byte) do
        <<byte>>
      else
        "%" <> Base.encode16(<<byte>>, case: :lower)
      end
    end
  end

  defp reserved_byte?(byte) do
    byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in ~c"._~-"
  end

  defp escape_markers(text) do
    Enum.reduce(@markers, text, fn marker, text ->
      String.replace(text, marker, escape_marker(marker))
    end)
  end

  defp escape_marker(marker) do
    String.replace_suffix(marker, "_", "%5f")
  end

  defp encode_file_identity(path) do
    extension = Path.extname(path)
    lowercase = String.downcase(extension)
    encoded = encode_identity(path)

    if extension == lowercase do
      encoded
    else
      # The marker keeps `a.CSS` distinct from `a.CSS.css` and literal suffixes.
      encoded <> @extension_marker <> lowercase
    end
  end

  # `Docs` and `docs` are one file on a case-insensitive disk. So are ß
  # and `ss`, and ﬁ and `fi`. A combining mark is one file with its composed
  # letter, and a Hangul syllable is one file with its jamo. The markers are
  # lowercase ASCII, so folding case or composition cannot merge them.
  defp encode_identity(path), do: encode_identity(path, [])

  defp encode_identity(<<codepoint::utf8, rest::binary>>, acc) do
    encode_identity(rest, [acc, encode_codepoint(<<codepoint::utf8>>)])
  end

  # A link can carry a byte that is not UTF-8, as in a Latin-1 stylesheet.
  # Percent-encode it so the snapshot still has a file and does not crash.
  defp encode_identity(<<byte, rest::binary>>, acc) do
    encode_identity(rest, [acc, "%", Base.encode16(<<byte>>, case: :lower)])
  end

  defp encode_identity(<<>>, acc), do: IO.iodata_to_binary(acc)

  defp encode_codepoint(codepoint) do
    <<code::utf8>> = codepoint

    cond do
      combining_mark?(code) ->
        @mark_marker <> code_hex(code)

      hangul_jamo?(code) ->
        @jamo_marker <> code_hex(code)

      code in ?A..?Z ->
        @case_marker <> String.downcase(codepoint)

      needs_case_marker?(codepoint) ->
        @case_marker <> code_hex(code)

      true ->
        codepoint
    end
  end

  # Downcase misses folds that still share a file: ß with ss, ﬁ with fi,
  # and µ with μ.
  defp needs_case_marker?(codepoint) do
    String.downcase(codepoint) != codepoint or :string.casefold(codepoint) != codepoint
  end

  # Six hex digits so a shorter value followed by a hex digit cannot equal
  # a longer one. U+0309 then "9" must not match U+3099.
  defp code_hex(code) do
    code
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(6, "0")
  end

  # Every Unicode mark, including the voiced mark in a decomposed hiragana
  # letter. APFS treats that sequence as the same file as the composed letter.
  defp combining_mark?(code) do
    Regex.match?(@combining_mark, <<code::utf8>>)
  end

  defp hangul_jamo?(code) do
    code in 0x1100..0x11FF or code in 0xA960..0xA97F or code in 0xD7B0..0xD7FF
  end
end
