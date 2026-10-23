defmodule Crawler.Parser do
  @moduledoc """
  Parses pages and calls a link handler to handle the detected links.

  Text input must be decoded UTF-8. For standalone calls, decode raw response
  bytes with [`Crawler.Charset.decode/2`](https://github.com/fredwu/crawler/blob/master/lib/crawler/charset.ex#L11) first. Managed callers must use
  [`Crawler.Charset.decode_result/3`](https://github.com/fredwu/crawler/blob/master/lib/crawler/charset.ex#L16), then pass the decoded source and its returned
  continuing allocation budget to `Crawler.Analysis.analyze/3`. Keep the same
  ledger through preparation, binding, and rendering. These facades do not
  implicitly decode input or reset the managed budget.
  """

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.Export.Producer
  alias Crawler.HTMLSpans
  alias Crawler.MediaType
  alias Crawler.Parser.Callbacks
  alias Crawler.Parser.CssSheets
  alias Crawler.Parser.Guarder
  alias Crawler.Parser.Prepared
  alias Crawler.Sitemap
  alias Crawler.URL

  require Logger

  defmodule Spec do
    @moduledoc """
    Spec for defining a parser.
    """

    alias Crawler.Store.Page

    @type url :: String.t()
    @type body :: String.t()
    @type opts :: map
    @type page :: %Page{url: url, body: body, opts: opts}

    @callback parse(page) :: {:ok, page} | {:error, term}
    @callback parse({:error, term}) :: :ok
  end

  @behaviour __MODULE__.Spec

  @doc """
  Parses the links and returns the page.

  Discovered links are sent to `Crawler.Dispatcher`. The scraper module in
  `page.opts[:scraper]` receives the page after link discovery. Its
  `scrape/1` result is returned. A tagged Sitemap ingestion error is returned
  without calling the scraper.

  A custom parser can use `parse_links/3` with its own link handler. Crawled
  data is also available asynchronously; see the
  [README](https://github.com/fredwu/crawler#usage).

  ## Examples

      iex> {:ok, page} = Parser.parse(%Page{
      iex>   body: "Body",
      iex>   opts: %{scraper: Crawler.Scraper, html_tag: "a", content_type: "text/html"}
      iex> })
      iex> page.body
      "Body"

      iex> {:ok, page} = Parser.parse(%Page{
      iex>   body: "<a href='http://parser/1'>Link</a>",
      iex>   opts: %{scraper: Crawler.Scraper, html_tag: "a", content_type: "text/html"}
      iex> })
      iex> page.body
      "<a href='http://parser/1'>Link</a>"

      iex> {:ok, page} = Parser.parse(%Page{
      iex>   body: "<a name='hello'>Link</a>",
      iex>   opts: %{scraper: Crawler.Scraper, html_tag: "a", content_type: "text/html"}
      iex> })
      iex> page.body
      "<a name='hello'>Link</a>"

      iex> {:ok, page} = Parser.parse(%Page{
      iex>   body: "<a href='http://parser/2' target='_blank'>Link</a>",
      iex>   opts: %{scraper: Crawler.Scraper, html_tag: "a", content_type: "text/html"}
      iex> })
      iex> page.body
      "<a href='http://parser/2' target='_blank'>Link</a>"

      iex> {:ok, page} = Parser.parse(%Page{
      iex>   body: "<a href='parser/2'>Link</a>",
      iex>   opts: %{scraper: Crawler.Scraper, html_tag: "a", content_type: "text/html", referrer_url: "http://hello"}
      iex> })
      iex> page.body
      "<a href='parser/2'>Link</a>"

      iex> {:ok, page} = Parser.parse(%Page{
      iex>   body: "<a href='../parser/2'>Link</a>",
      iex>   opts: %{scraper: Crawler.Scraper, html_tag: "a", content_type: "text/html", referrer_url: "http://hello"}
      iex> })
      iex> page.body
      "<a href='../parser/2'>Link</a>"

      iex> {:ok, page} = Parser.parse(%Page{
      iex>   body: image_file(),
      iex>   opts: %{scraper: Crawler.Scraper, html_tag: "img", content_type: "image/png"}
      iex> })
      iex> page.body
      "\#{image_file()}"
  """
  def parse(input)

  def parse({:warn, reason}), do: Logger.debug(fn -> "#{inspect(reason)}" end)
  def parse({:error, _reason}), do: Logger.error("Crawl failed")

  def parse(%{opts: opts} = page) do
    with {:ok, prepared} <- page_preparation(page),
         {:ok, prepared, credit, control?} <- ingest_page(prepared, Map.get(page, :credit)),
         :ok <- Producer.discover(prepared, credit, control?) do
      opts = if control?, do: Map.put(opts, :count_page, false), else: opts
      previous = page
      page = %{page | opts: opts}

      page =
        if is_struct(page, Crawler.Store.Page) and is_map(credit) do
          updated = %{
            page
            | interpretation: prepared,
              analysis: prepared.analysis,
              credit: credit
          }

          Crawler.Store.Execution.advance_funded_page(previous, updated)
        else
          page
        end

      opts[:scraper].scrape(page)
    end
  end

  defp ingest_page(prepared, %{} = credit), do: Sitemap.ingest_prepared(prepared, credit)

  defp ingest_page(prepared, credit) do
    case Sitemap.ingest(prepared.opts, prepared.source) do
      result when is_boolean(result) -> {:ok, prepared, credit, result}
      error -> error
    end
  end

  @doc """
  Discovers references and calls the handler with the existing element tuples.

  The `body` must be decoded UTF-8. Invalid UTF-8 in supported text returns
  `{:error, :invalid_utf8}`.

  Returns handler results grouped by source element. Unsupported response roles
  return an empty list. Invalid or limited supported analysis returns a tagged
  error, so managed callers can settle that outcome.
  """
  def parse_links(body, opts, handler) do
    with {:ok, prepared} <- prepare_for_parse(body, opts), do: emit(prepared, handler)
  end

  @doc false
  def prepare(%Analysis{} = analysis, opts, css_context) do
    opts = source_options(analysis, opts)

    if parseable?(opts) do
      with {:ok, groups} <- stylesheet_groups(analysis, opts) do
        do_prepare_collection(analysis, opts, css_context, groups)
      end
    else
      {:ok, opaque(original_source(analysis), opts, analysis)}
    end
  end

  @doc false
  def prepare_for_parse(source_or_analysis, opts) do
    if parseable?(opts) do
      with {:ok, analysis, opts} <- lexical_analysis(source_or_analysis, opts),
           opts <- source_options(analysis, opts),
           {:ok, groups} <- stylesheet_groups(analysis, opts),
           {:ok, context} <- stylesheet_context(groups, opts) do
        do_prepare_collection(analysis, opts, context, groups)
      end
    else
      {:ok, opaque(original_source(source_or_analysis), opts)}
    end
  end

  @doc false
  def prepare_collection(
        %Analysis{} = analysis,
        opts,
        css_context,
        %{groups: _groups} = css_collection
      ) do
    do_prepare_collection(analysis, source_options(analysis, opts), css_context, css_collection)
  end

  def prepare_collection(%Analysis{}, _opts, _css_context, _css_collection),
    do: {:error, :invalid_budget_continuation}

  defp do_prepare_collection(analysis, opts, css_context, css_collection) do
    with :ok <- managed_snapshot(opts, css_context, css_collection),
         {:ok, collection} <-
           occurrence_collection(analysis, Map.merge(opts, css_context), css_collection),
         {:ok, collection} <- retain_css_revision(collection, css_context),
         {:ok, collection} <- retain_control_result(collection, analysis, opts),
         {:ok, groups, members, collection} <- Callbacks.prepare(analysis, opts, collection) do
      {:ok,
       %Prepared{
         source: original_source(analysis),
         analysis: analysis,
         analysis_revision: analysis.revision,
         source_revision: opts[:source_revision],
         opts: opts,
         context_key: preparation_key(opts),
         occurrences: collection.occurrences,
         collection: collection,
         css_collection: css_collection,
         css_revision: css_context[:css_revision],
         groups: groups,
         callback_members: members
       }}
    end
  end

  defp retain_css_revision(collection, %{css_revision: revision}) when not is_nil(revision) do
    with {:ok, budget} <- Budget.charge(collection.budget, Budget.cost(:context)),
         do: {:ok, %{collection | budget: budget}}
  end

  defp retain_css_revision(collection, _context), do: {:ok, collection}

  defp retain_control_result(collection, %{mode: :xml}, opts) do
    if MediaType.feed?(opts[:content_type]) or MediaType.xml?(opts[:content_type]) do
      with {:ok, budget} <- Budget.charge(collection.budget, 256),
           do: {:ok, Map.merge(collection, %{budget: budget, control_document: :pending})}
    else
      {:ok, collection}
    end
  end

  defp retain_control_result(collection, _analysis, _opts), do: {:ok, collection}

  defp occurrence_collection(analysis, context, nil),
    do: Analysis.occurrences_result(analysis, context)

  defp occurrence_collection(analysis, context, css_collection),
    do: Analysis.occurrences_result(analysis, context, css_collection)

  @doc false
  def emit(%Prepared{} = prepared, handler) do
    occurrences = if prepared.collection, do: prepared.collection.occurrences, else: []
    Callbacks.emit(prepared.groups, occurrences, prepared.opts, handler)
  end

  @doc false
  def emit_bound(%Prepared{collection: nil, groups: []}, _handler, _observer), do: []

  def emit_bound(%Prepared{callback_members: members} = prepared, handler, observer)
      when is_map(members) do
    Callbacks.emit_bound(
      prepared.groups,
      prepared.collection.occurrences,
      prepared.opts,
      members,
      handler,
      observer
    )
  end

  def emit_bound(%Prepared{}, _handler, _observer), do: {:error, :missing_callback_members}

  defp page_preparation(%{body: body, opts: opts} = page) do
    case Map.get(page, :interpretation) do
      %Prepared{source: ^body} = prepared ->
        current = source_options(prepared.analysis, opts)

        if preparation_key(current) == prepared.context_key,
          do: {:ok, %{prepared | opts: current}},
          else: prepare_for_parse(prepared.analysis || body, opts)

      _other ->
        prepare_for_parse(Map.get(page, :analysis) || body, opts)
    end
  end

  defp lexical_analysis(%Analysis{mode: {:javascript, cached_goal}} = analysis, opts) do
    goal = opts[:javascript_goal] || :module

    if goal == cached_goal,
      do: {:ok, analysis, opts},
      else: lexical_analysis(original_source(analysis), opts)
  end

  defp lexical_analysis(%Analysis{} = analysis, opts), do: {:ok, analysis, opts}

  defp lexical_analysis(source, opts) do
    opts = if is_nil(opts[:generation]), do: opts, else: Crawler.Limits.validate!(opts)

    options =
      if is_nil(opts[:generation]),
        do: opts,
        else: Map.merge(opts, Map.new(Crawler.Limits.analysis(opts)))

    with {:ok, analysis} <- Analysis.analyze(source, options), do: {:ok, analysis, opts}
  end

  defp stylesheet_groups(analysis, opts) do
    if is_nil(opts[:generation]),
      do: {:ok, nil},
      else: Analysis.css_groups_result(analysis, opts)
  end

  defp stylesheet_context(nil, _opts), do: {:ok, %{}}
  defp stylesheet_context(%{groups: []}, _opts), do: {:ok, %{}}

  defp stylesheet_context(%{groups: groups}, opts),
    do: CssSheets.resolve_groups(opts, groups)

  defp managed_snapshot(_opts, _context, nil), do: :ok
  defp managed_snapshot(_opts, _context, %{groups: []}), do: :ok

  defp managed_snapshot(_opts, context, _groups) do
    cond do
      not Map.has_key?(context, :css_tokens) -> {:error, :missing_managed_css_snapshot}
      context[:css_revision] == nil -> {:error, :missing_css_revision}
      true -> :ok
    end
  end

  defp parseable?(opts) do
    opts[:fetch_kind] in [:manifest, :speculation_rules, :source_map] or Guarder.pass?(opts)
  end

  defp original_source(%Analysis{} = analysis), do: analysis.regions[analysis.root].source
  defp original_source(source), do: source

  @doc false
  def opaque(source, opts, analysis \\ nil) do
    %Prepared{
      source: source,
      analysis: analysis,
      opts: opts,
      occurrences: [],
      groups: [],
      source_revision: opts[:source_revision],
      analysis_revision: if(analysis, do: analysis.revision),
      context_key: preparation_key(opts)
    }
  end

  defp source_options(nil, opts), do: opts

  defp source_options(analysis, opts) do
    kind = analysis.regions[analysis.root].kind

    cond do
      opts[:srcdoc] == true ->
        Map.put(opts, :style_group, {:srcdoc, opts[:url], analysis.revision})

      kind in [:html, :xml] ->
        put_document_group(opts)

      kind == :css ->
        Map.put_new(opts, :style_group, opts[:url] || opts[:referrer_url])

      true ->
        opts
    end
  end

  defp put_document_group(opts) do
    case opts[:url] || opts[:referrer_url] do
      url when is_binary(url) and url != "" -> Map.put(opts, :style_group, url)
      _other -> opts
    end
  end

  defp preparation_key(opts) do
    {Analysis.context_key(opts),
     Map.take(opts, [
       :assets,
       :respect_robots,
       :user_agent,
       :robots_nofollow,
       :content_type,
       :headers
     ])}
  end

  @doc false
  def with_document_base(body, opts) do
    if MediaType.document_mode(opts[:content_type]) == :html do
      case HTMLSpans.base_tags(body) do
        [tag | _rest] -> put_base(HTMLSpans.value(tag, "href"), opts)
        [] -> opts
      end
    else
      opts
    end
  end

  defp put_base(href, opts) do
    case URL.resolve(href, opts[:referrer_url] || opts[:url] || "") do
      {:ok, url} ->
        path = URI.parse(URL.sanitize(href)).path || ""
        uri = URI.parse(url)

        url =
          if String.ends_with?(path, "/"),
            do: URI.to_string(%{uri | path: String.trim_trailing(uri.path || "", "/") <> "/"}),
            else: url

        Map.put(opts, :referrer_url, url)

      :skip ->
        opts
    end
  end

  @doc false
  def assigned_style_group(body, opts) do
    case Analysis.analyze(body, opts) do
      {:ok, analysis} -> source_options(analysis, opts)[:style_group]
      {:error, _reason} -> nil
    end
  end
end
