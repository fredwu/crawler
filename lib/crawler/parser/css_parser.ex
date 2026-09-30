defmodule Crawler.Parser.CssParser do
  @moduledoc """
  Parses CSS files.
  """

  @import_pattern ~r/@import\s+(?!url\()['"](?!data:)([^'"]+)['"]/i
  @url_pattern ~r/url\(\s*(?:'((?!data:)[^']*)'|"((?!data:)[^"]*)"|(?!['"])((?!data:)[^)\s]+))\s*\)/i

  @doc """
  Parses CSS files.

  ## Examples

      iex> CssParser.parse(
      iex>   "img { url(http://hello.world) }"
      iex> )
      [{"link", [{"href", "http://hello.world"}], []}]

      iex> CssParser.parse(
      iex>   "@font-face { src: url('icons.ttf') format('truetype'); }"
      iex> )
      [{"link", [{"href", "icons.ttf"}], []}]

      iex> CssParser.parse(
      iex>   "@font-face { src: url('data:application/blah'); }"
      iex> )
      []

      iex> CssParser.parse("@import 'other.css';")
      [{"link", [{"href", "other.css"}], []}]

      iex> CssParser.parse("@import url(\\"nested.css\\");")
      [{"link", [{"href", "nested.css"}], []}]

      iex> CssParser.parse("body { background: url( \\"spaced.png\\" ); }")
      [{"link", [{"href", "spaced.png"}], []}]

      iex> CssParser.parse("@font-face { src: url( 'font.woff2' ); }")
      [{"link", [{"href", "font.woff2"}], []}]

      iex> CssParser.parse(~s|div { background: image-set("wide.png" 1x, "narrow.png" 2x); }|)
      [
        {"link", [{"href", "wide.png"}], []},
        {"link", [{"href", "narrow.png"}], []}
      ]

      iex> CssParser.parse(~s|div { background: image-set("wide.png" type("image/png") 1x); }|)
      [{"link", [{"href", "wide.png"}], []}]

      iex> CssParser.parse(~s|div { background: image-set(url("a.png") 1x, "b.png" 2x); }|)
      [
        {"link", [{"href", "a.png"}], []},
        {"link", [{"href", "b.png"}], []}
      ]

      iex> CssParser.parse(~s|div { background: image-set(wide.png 1x, narrow.png 2x); }|)
      [
        {"link", [{"href", "wide.png"}], []},
        {"link", [{"href", "narrow.png"}], []}
      ]

      iex> CssParser.parse(~s|div { background: image-set(url("data:image/png;base64,abc") 1x, "b.png" 2x); }|)
      [{"link", [{"href", "b.png"}], []}]

      iex> CssParser.parse(~s|div { background: image-set("DATA:image/png,aaa" 1x, "b.png" 2x); }|)
      [{"link", [{"href", "b.png"}], []}]

      iex> CssParser.parse(~s|div { background: image-set("a.png" 1x, url("data:image/gif,xx") 2x, "b.png" 3x); }|)
      [
        {"link", [{"href", "a.png"}], []},
        {"link", [{"href", "b.png"}], []}
      ]

      iex> CssParser.parse(~s|div { background: image-set("data:text/css,body{background:url('a.png')}" 1x, "b.png" 2x); }|)
      [{"link", [{"href", "b.png"}], []}]
  """
  def parse(body) when is_binary(body) do
    body = mask_data_strings(body)

    (captures(@import_pattern, body) ++ captures(@url_pattern, body) ++ image_set_urls(body))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.map(&prep_css_element/1)
  end

  def parse(_body), do: []

  defp captures(regex, body) do
    regex
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn groups -> Enum.find(groups, &(&1 != "")) end)
    |> Enum.reject(&is_nil/1)
  end

  defp prep_css_element(link) do
    {"link", [{"href", link}], []}
  end

  defp image_set_urls(body) do
    body
    |> image_set_spans()
    |> Enum.flat_map(fn {_start, inner} -> region_urls(inner) end)
  end

  @doc false
  def image_set_spans(body) when is_binary(body), do: spans(body, 0, [])
  def image_set_spans(_body), do: []

  defp spans(body, offset, acc) do
    case Regex.run(~r/image-set\s*\(/i, body, return: :index) do
      [{index, length} | _] ->
        inner_at = index + length
        rest = binary_part(body, inner_at, byte_size(body) - inner_at)
        {inner, tail} = take_group(rest, 1, [], nil)
        inner = IO.iodata_to_binary(inner)
        consumed = byte_size(rest) - byte_size(tail)

        spans(tail, offset + inner_at + consumed, [{offset + inner_at, inner} | acc])

      _ ->
        Enum.reverse(acc)
    end
  end

  defp take_group(<<>>, _depth, acc, _quote), do: {Enum.reverse(acc), ""}

  defp take_group(<<quote, rest::binary>>, depth, acc, nil) when quote in [?", ?'] do
    take_group(rest, depth, [<<quote>> | acc], quote)
  end

  defp take_group(<<?\\, char::utf8, rest::binary>>, depth, acc, quote) when not is_nil(quote) do
    take_group(rest, depth, [<<char::utf8>>, "\\" | acc], quote)
  end

  defp take_group(<<?\\, char, rest::binary>>, depth, acc, quote) when not is_nil(quote) do
    take_group(rest, depth, [<<char>>, "\\" | acc], quote)
  end

  defp take_group(<<quote, rest::binary>>, depth, acc, quote) do
    take_group(rest, depth, [<<quote>> | acc], nil)
  end

  defp take_group(<<?), rest::binary>>, 1, acc, nil), do: {Enum.reverse(acc), rest}

  defp take_group(<<?), rest::binary>>, depth, acc, nil) do
    take_group(rest, depth - 1, [?) | acc], nil)
  end

  defp take_group(<<?(, rest::binary>>, depth, acc, nil) do
    take_group(rest, depth + 1, [?( | acc], nil)
  end

  defp take_group(<<char::utf8, rest::binary>>, depth, acc, quote) do
    take_group(rest, depth, [<<char::utf8>> | acc], quote)
  end

  defp take_group(<<char, rest::binary>>, depth, acc, quote) do
    take_group(rest, depth, [<<char>> | acc], quote)
  end

  defp region_urls(region) do
    stripped = String.replace(region, ~r/type\s*\((?:[^)"']|"[^"]*"|'[^']*')*\)/i, " ")

    capture_quotes(stripped) ++ bare_urls(stripped) ++ nested_image_set_urls(region)
  end

  # The outer call consumes nested image-set() as parentheses, so the inner
  # file is not its own span. Scan the inner text again.
  defp nested_image_set_urls(region) do
    region
    |> image_set_spans()
    |> Enum.flat_map(fn {_start, inner} -> region_urls(inner) end)
  end

  # A quote starts a candidate only at a value boundary. The matching quote
  # ends it, so a data URL keeps the quotes inside its payload and the next
  # file is still found.
  defp capture_quotes(region) do
    ~r/(?:^|[\s,(])(?:"((?:\\.|[^"])*)"|'((?:\\.|[^'])*)')/s
    |> Regex.scan(region, capture: :all_but_first)
    |> Enum.flat_map(fn groups ->
      url = Enum.find(groups, "", &(&1 != ""))
      if url == "" or data_url?(url), do: [], else: [url]
    end)
  end

  defp data_url?(url), do: String.match?(url, ~r/^\s*data:/i)

  # A data URL is one token. `url()` and quotes inside its payload are not files.
  defp mask_data_strings(text) do
    Regex.replace(~r/"(?:\\.|[^"])*"|'(?:\\.|[^'])*'/s, text, fn quoted ->
      inner = binary_part(quoted, 1, max(byte_size(quoted) - 2, 0))
      if data_url?(inner), do: String.duplicate(" ", byte_size(quoted)), else: quoted
    end)
  end

  defp bare_urls(region) do
    region
    |> String.replace(~r/"[^"]*"|'[^']*'/, " ")
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.filter(&bare_url?/1)
  end

  defp bare_url?(token) do
    String.match?(token, ~r/[A-Za-z0-9]/) and
      (String.contains?(token, "/") or String.contains?(token, ".")) and
      not String.contains?(token, ["(", ")"]) and
      not String.match?(token, ~r/^data:/i) and
      not descriptor?(token)
  end

  defp descriptor?(token), do: String.match?(token, ~r/^\d+(\.\d+)?(x|dpi|dppx)$/i)
end
