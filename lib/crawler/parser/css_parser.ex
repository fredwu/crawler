defmodule Crawler.Parser.CssParser do
  @moduledoc """
  Parses CSS files.
  """

  alias Crawler.HTMLSpans
  alias Crawler.Parser.CssParser.Scanner
  alias Crawler.Parser.CssParser.Value

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
  def parse(body) do
    body
    |> spans()
    |> Enum.map(& &1.value)
    |> Enum.uniq()
    |> Enum.map(&{"link", [{"href", &1}], []})
  end

  @doc false
  def spans(body, opts \\ [])

  def spans(body, opts) when is_binary(body) do
    body
    |> resource_spans(Keyword.get(opts, :entity_quotes, false))
    |> Enum.reject(fn token -> token.value == "" or data_url?(token.value) end)
  end

  def spans(_body, _opts), do: []

  defp resource_spans(body, false), do: Scanner.resources(body)

  defp resource_spans(body, true) do
    {decoded, segments} = HTMLSpans.decode_with_spans(body)

    decoded
    |> Scanner.resources()
    |> Enum.map(fn token ->
      {start, length} = HTMLSpans.source_span(segments, {token.start, token.length})

      quote =
        if token.quote == "", do: "", else: Value.source_quote(binary_part(body, start, length))

      %{token | start: start, length: length, quote: quote}
    end)
  end

  defp data_url?(value), do: Regex.match?(~r/^\s*data:/i, value)
end
