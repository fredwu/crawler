defmodule Crawler.Snapper.LinkReplacer do
  @moduledoc """
  Rewrites references from one shared source analysis.

  Standalone rewriting preserves safe online destinations. Managed exports pass
  the prepared occurrence collection, bound target handles, and their manifest
  resolver to `replace_prepared/3`.

  Text input must be decoded UTF-8. For standalone calls, decode raw response
  bytes with [`Crawler.Charset.decode/2`](https://github.com/fredwu/crawler/blob/master/lib/crawler/charset.ex#L11) first. Managed callers must use
  [`Crawler.Charset.decode_result/3`](https://github.com/fredwu/crawler/blob/master/lib/crawler/charset.ex#L16), then pass the decoded source and its returned
  continuing allocation budget to `Crawler.Analysis.analyze/3`. Keep the same
  ledger through preparation, binding, and rendering. These facades do not
  implicitly decode input or reset the managed budget.
  """

  alias Crawler.Analysis
  alias Crawler.Parser
  alias Crawler.Parser.Prepared

  @doc """
  Resolves supported references to online URLs without URL userinfo.

  The `body` must be decoded UTF-8. Invalid UTF-8 in supported text returns
  `{:error, :invalid_utf8}`.

      iex> LinkReplacer.replace_links("<a href='next'>Next</a>", %{
      ...>   url: "https://example.test/dir/page", content_type: "text/html", html_tag: "a"
      ...> })
      {:ok, "<a href='https://example.test/dir/next'>Next</a>"}
  """
  def replace_links(body, opts) do
    with {:ok, prepared} <- Parser.prepare_for_parse(body, opts) do
      replace_prepared(prepared, &Analysis.online_fallback/1)
    end
  end

  @doc false
  def bind_prepared(%Prepared{analysis: nil} = prepared, _target_handle), do: {:ok, prepared}

  def bind_prepared(%Prepared{collection: collection} = prepared, target_handle) do
    with {:ok, bound} <- Analysis.bind(collection, target_handle),
         do: {:ok, %{prepared | collection: bound, occurrences: bound.occurrences}}
  end

  @doc false
  def replace_prepared(prepared, resolver, options \\ [])

  def replace_prepared(%Prepared{analysis: nil, source: source}, _resolver, _options),
    do: {:ok, source}

  def replace_prepared(%Prepared{} = prepared, resolver, options),
    do: Analysis.render(prepared.analysis, prepared.collection, resolver, options)
end
