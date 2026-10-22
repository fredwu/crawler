defmodule Crawler.Parser.CssParser do
  @moduledoc """
  Parses CSS files.
  """

  alias Crawler.HTMLSpans
  alias Crawler.Parser.CssParser.DocumentStyles
  alias Crawler.Parser.CssParser.Scanner
  alias Crawler.Parser.CssParser.Value
  alias Crawler.Parser.CssParser.Variables
  alias Crawler.Parser.CssSheets

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

      iex> CssParser.parse(~s|div { background: image("wide.png"); }|)
      [{"link", [{"href", "wide.png"}], []}]

      iex> CssParser.parse(~s|div { background: image(ltr "left.png", #ccc); }|)
      [{"link", [{"href", "left.png"}], []}]

      iex> CssParser.parse(~s|div { background: image(url("already.png")); }|)
      [{"link", [{"href", "already.png"}], []}]

      iex> CssParser.parse(~s|div { background: image("data:image/png,aaa"); }|)
      []

      iex> CssParser.parse(~s|div { background: image(wide.png); }|)
      []
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
    opts = span_options(opts)
    mode = Map.get(opts, :mode, :stylesheet)
    {analysis, segments} = analyzed(body, mode, Map.get(opts, :entity_quotes, false) == true)

    analysis.resources
    |> Kernel.++(variable_tokens(opts, body, analysis))
    |> map_tokens(segments, body)
    |> Enum.uniq_by(fn token -> {token.start, token.length} end)
    |> Enum.sort_by(& &1.start)
    |> Enum.reject(&ignored_token?/1)
  end

  def spans(_body, _opts), do: []

  defp analyzed(body, mode, false), do: {Scanner.analyze(body, mode: mode), nil}

  defp analyzed(body, mode, true) do
    {decoded, segments} = HTMLSpans.decode_with_spans(body)
    {Scanner.analyze(decoded, mode: mode), segments}
  end

  defp variable_tokens(opts, body, analysis) do
    if opts[:document_styles] && Map.get(opts, :mode, :stylesheet) == :stylesheet do
      DocumentStyles.tokens(opts.document_styles, opts[:document_style_id], analysis)
    else
      case CssSheets.remember(opts, body, analysis) do
        {:ok, tokens} -> tokens
        :local -> Variables.span_tokens(analysis)
      end
    end
  end

  defp map_tokens(tokens, nil, _body), do: tokens

  defp map_tokens(tokens, segments, body) do
    Enum.map(tokens, &map_token(&1, segments, body))
  end

  defp map_token(token, segments, body) do
    {start, length} = HTMLSpans.source_span(segments, {token.start, token.length})
    quote = mapped_quote(token, body, start, length)
    %{token | start: start, length: length, quote: quote}
  end

  defp mapped_quote(%{quote: ""}, _body, _start, _length), do: ""

  defp mapped_quote(_token, body, start, length) do
    Value.source_quote(binary_part(body, start, length))
  end

  defp span_options(opts) when is_list(opts), do: Map.new(opts)
  defp span_options(opts) when is_map(opts), do: opts
  defp span_options(_opts), do: %{}

  defp ignored_token?(%{value: value}) when is_binary(value) do
    value == "" or data_url?(value) or fragment?(value)
  end

  defp ignored_token?(_token), do: true

  defp data_url?(value), do: Regex.match?(~r/^\s*data:/i, value)
  defp fragment?(value), do: value |> String.trim() |> String.starts_with?("#")
end
