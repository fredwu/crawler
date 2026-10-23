defmodule Crawler.Sitemap do
  @moduledoc false

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.Charset
  alias Crawler.Deadline
  alias Crawler.Fetcher.Requester
  alias Crawler.Fetcher.Retrier
  alias Crawler.HTMLReferences
  alias Crawler.HTTP
  alias Crawler.Limits
  alias Crawler.MediaType
  alias Crawler.Parser.Prepared
  alias Crawler.QueueHandler
  alias Crawler.Site
  alias Crawler.Sitemap.Document
  alias Crawler.Store
  alias Crawler.Store.Execution
  alias Crawler.URL

  @catalogs [:urlset, :sitemapindex, :rss, :atom, :rdf]

  def follow(opts, origin, rules) when is_map(rules) do
    opts = document_opts(opts)

    rules
    |> Map.get(:sitemaps, [])
    |> Enum.reduce_while(:ok, fn url, :ok ->
      result =
        with :ok <- check_deadline(opts),
             {:ok, absolute} <- URL.resolve(url, origin <> "/") do
          enqueue_control(opts, absolute, 0)
        else
          :skip -> :ok
          error -> error
        end

      continue(result)
    end)
  end

  def follow(_opts, _origin, _rules), do: :ok

  def execute(opts, prepared) do
    opts = document_opts(opts)
    retrier = opts[:retrier] || Retrier

    with :ok <- check_deadline(opts),
         {:ok, response} <- retrier.perform(fn -> request(opts, prepared) end, opts),
         {:ok, _analysis} <- Store.reserve_resource(opts, :analysis, opts.max_analysis_bytes),
         {:ok, body} <- inflate(response.body, opts),
         :ok <- Store.account_control_bytes(account_opts(opts, response), byte_size(body)),
         {:ok, document} <- Document.parse(body, final_url(response, opts.url), opts) do
      admit_entries(opts, document.entries)
    else
      {:warn, reason} -> {:error, reason}
      error -> error
    end
  end

  def ingest(opts, body) when is_map(opts) and is_binary(body) do
    opts = opts |> Crawler.Options.assign_defaults() |> document_opts()

    cond do
      not control_type?(opts) -> false
      byte_size(body) > opts.max_body -> {:error, {:limit, :max_body}}
      true -> Execution.run(opts, &ingest_binary(&1, body))
    end
  end

  def ingest(_opts, _body), do: false

  def ingest_prepared(%Prepared{} = prepared, credit) do
    if control_type?(prepared.opts) and match?(%Analysis{mode: :xml}, prepared.analysis) do
      ingest_collection(prepared, credit)
    else
      {:ok, prepared, credit, false}
    end
  end

  defp ingest_collection(%{collection: %{control_document: result}} = prepared, credit)
       when is_boolean(result),
       do: {:ok, prepared, credit, result}

  defp ingest_collection(
         %{collection: %{budget: budget, control_document: :pending}} = prepared,
         %{} = credit
       ) do
    opts = document_opts(prepared.opts)
    available = Budget.available(budget)

    with :ok <- check_deadline(opts),
         {:ok, receipt, capacity} <- Store.reserve_resource_up_to(opts, :analysis, available) do
      try do
        with {:ok, seed} <- Budget.charge(budget, available - capacity),
             {:ok, advanced, result} <- ingest_document(prepared, opts, seed, receipt),
             {:ok, updated} <- Budget.refund(advanced, advanced.retained - seed.retained) do
          collection =
            Map.merge(prepared.collection, %{budget: updated, control_document: result})

          credit = %{credit | unavailable: credit.unavailable + available - capacity}
          {:ok, %{prepared | collection: collection}, credit, result}
        end
      after
        Store.release_resource(receipt)
      end
    end
  end

  defp ingest_collection(_prepared, _credit), do: {:error, :unfunded_control_document}

  defp ingest_document(prepared, opts, seed, receipt) do
    with {:ok, document, collection} <-
           Document.from_analysis(prepared.analysis, %{prepared.collection | budget: seed}, opts),
         :ok <- Store.commit_resource(receipt, collection.budget.retained - seed.retained),
         result = document.kind in @catalogs,
         :ok <- ingest_entries(opts, document, result) do
      {:ok, collection.budget, result}
    end
  end

  defp ingest_binary(opts, input) do
    capacity =
      if match?(<<31, 139, _::binary>>, input),
        do: 2 * opts.max_body + 65_536,
        else: :binary.referenced_byte_size(input) + 128

    with :ok <- check_deadline(opts),
         {:ok, body_receipt} <- Store.reserve_resource(opts, :source, capacity),
         {:ok, body} <- inflate(input, opts),
         retained = if(:erts_debug.same(input, body), do: input, else: {input, body}),
         {:ok, bytes} <- Crawler.Store.Retained.bytes(retained, capacity),
         :ok <- Store.commit_resource(body_receipt, bytes),
         {:ok, receipt, available} <-
           Store.reserve_resource_up_to(opts, :analysis, opts.max_analysis_bytes),
         {:ok, seed} <-
           Budget.charge(Budget.new(Limits.analysis(opts)), opts.max_analysis_bytes - available),
         {:ok, decoded, budget} <- Charset.decode_result(body, opts, seed),
         {:ok, analysis} <-
           Analysis.analyze(decoded, Map.merge(opts, Limits.analysis(opts)), budget),
         {:ok, document, collection} <-
           Document.from_analysis(
             analysis,
             %{source_revision: analysis.revision, budget: analysis.budget},
             opts
           ),
         :ok <- Store.commit_resource(receipt, collection.budget.retained - seed.retained),
         result = document.kind in @catalogs,
         :ok <-
           ingest_entries(Map.put(opts, :source_entity_bytes, byte_size(body)), document, result) do
      result
    end
  end

  defp ingest_entries(opts, document, true) do
    with :ok <- Store.account_control_document(opts),
         :ok <-
           Store.account_control_bytes(
             opts,
             opts[:source_entity_bytes] || document.stats.decoded_bytes
           ),
         do: admit_entries(opts, document.entries)
  end

  defp ingest_entries(_opts, _document, false), do: :ok

  defp control_type?(opts),
    do: MediaType.feed?(opts[:content_type]) or MediaType.xml?(opts[:content_type])

  @doc false
  def locations(body) when is_binary(body) do
    case Document.parse(body, "https://example.test/control.xml", Limits.defaults()) do
      {:ok, %{entries: entries}} ->
        {for(entry <- entries, entry.role == :page, do: entry.raw),
         for(entry <- entries, entry.role == :control, do: entry.raw)}

      {:error, _reason} ->
        {[], []}
    end
  end

  defp request(opts, prepared) do
    with :ok <- check_deadline(opts) do
      response =
        if opts[:scheduler_kind] == :sitemap,
          do: Crawler.Fetcher.control_request(opts),
          else: Requester.send(prepared, Map.put(opts, :control_accounting, true))

      case response do
        {:ok, %{status: status, body: body} = response}
        when status in 200..299 and is_binary(body) ->
          {:ok, response}

        {:ok, %{status: status}} when status in [408, 429] or status >= 500 ->
          {:error, {:http_status, status}}

        {:ok, %{status: status}} ->
          {:warn, {:http_status, status}}

        {:error, %HTTP.BodyTooLarge{}} ->
          {:warn, {:limit, :max_body}}

        {:error, %HTTP.BodyLimitExceeded{reason: reason}} ->
          {:warn, reason}

        {:error, %HTTP.DeadlineExceeded{reason: reason}} ->
          {:warn, reason}

        {:error, %HTTP.StaleExecution{}} ->
          {:warn, :stale}

        {:error, %HTTP.UnsupportedEncoding{}} ->
          {:warn, :unsupported_encoding}

        {:error, %HTTP.RedirectRejected{}} ->
          {:warn, :redirect_rejected}

        {:error, {kind, _detail} = reason} when kind in [:limit, :deadline] ->
          {:warn, reason}

        {:error, reason} when reason in [:stale, :cancelled] ->
          {:warn, reason}

        error ->
          error
      end
    else
      {:error, reason} -> {:warn, reason}
    end
  end

  defp admit_entries(opts, entries) do
    {references, controls} = Enum.split_with(entries, &(&1.role != :control))

    with :ok <- admit_all(references, opts), do: admit_all(controls, opts)
  end

  defp admit_all(entries, opts) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      result = with :ok <- check_deadline(opts), do: admit_entry(opts, entry)
      continue(result)
    end)
  end

  defp admit_entry(opts, %{role: :control, url: url}) do
    enqueue_control(opts, url, (opts[:control_depth] || 0) + 1)
  end

  defp admit_entry(opts, %{role: :page, url: url}) do
    if page_in_scope?(opts, url) do
      opts |> page_opts() |> then(&Crawler.crawl_reference(url, &1)) |> admission_result()
    else
      :ok
    end
  end

  defp admit_entry(opts, %{role: :image, url: url}) do
    if HTMLReferences.enabled?(opts, "images") do
      opts |> image_opts() |> then(&Crawler.crawl_reference(url, &1)) |> admission_result()
    else
      :ok
    end
  end

  defp enqueue_control(opts, url, depth) do
    control_opts =
      opts
      |> shared_opts()
      |> Map.merge(%{
        url: url,
        cookie_site: document_site(opts),
        cookie_navigation: false,
        sitemap_fetch: true,
        count_page: false,
        control_depth: depth
      })

    QueueHandler.enqueue_control(url, control_opts) |> admission_result()
  end

  defp admission_result({:error, _reason} = error), do: error
  defp admission_result({:ok, _opts}), do: :ok
  defp admission_result(:ok), do: :ok

  defp continue(:ok), do: {:cont, :ok}
  defp continue({:error, _reason} = error), do: {:halt, error}

  defp page_in_scope?(opts, url) do
    case opts[:site] do
      site when is_binary(site) -> Site.same_site?(site, url)
      _ -> true
    end
  end

  defp page_opts(opts) do
    opts
    |> shared_opts()
    |> Map.put(:html_tag, "a")
    |> Map.put(:cookie_site, document_site(opts))
  end

  defp image_opts(opts) do
    opts
    |> shared_opts()
    |> Map.put(:html_tag, "img")
    |> Map.put(:reference_tag, "img")
    |> Map.put(:cookie_site, document_site(opts))
  end

  defp document_site(opts), do: opts[:cookie_site] || opts[:url]

  defp shared_opts(opts) do
    opts
    |> Map.drop([
      :alias_candidate,
      :alias_created,
      :alias_url,
      :before_publish,
      :content_type,
      :control_depth,
      :control_sequence,
      :deadline,
      :headers,
      :cookie_navigation,
      :credentials,
      :page_open,
      :reference_tag,
      :referrer_url,
      :robots_fetch,
      :robots_nofollow,
      :count_page,
      :fetch_kind,
      :sitemap_fetch,
      :source_entity_bytes,
      :url
    ])
    |> Map.put(:depth, 1)
    |> Map.put(:force, false)
  end

  defp document_opts(opts) do
    case opts[:deadline] || opts[:crawler_deadline] do
      nil -> opts
      deadline -> Map.put(opts, :deadline, deadline)
    end
  end

  defp check_deadline(opts) do
    case opts[:deadline] do
      nil -> :ok
      deadline -> Deadline.check(deadline)
    end
  end

  defp account_opts(opts, response) do
    case Req.Response.get_private(response, :crawler_control_sequence) do
      sequence when is_integer(sequence) and sequence >= 0 ->
        Map.put(opts, :control_sequence, sequence)

      _ ->
        Map.delete(opts, :control_sequence)
    end
  end

  defp final_url(response, fallback) do
    case Req.Response.get_private(response, :crawler_url) do
      url when is_binary(url) and url != "" -> url
      _ -> fallback
    end
  end

  defp inflate(body, opts) when byte_size(body) > opts.max_body,
    do: {:error, {:limit, :max_body}}

  defp inflate(<<31, 139, _rest::binary>> = body, opts) do
    zlib = :zlib.open()

    try do
      :zlib.inflateInit(zlib, 16 + 15)

      with {:ok, chunks} <- inflate_limited(zlib, body, opts, 0, []),
           :ok <- check_deadline(opts) do
        :zlib.inflateEnd(zlib)
        {:ok, IO.iodata_to_binary(Enum.reverse(chunks))}
      end
    rescue
      ErlangError -> {:error, :invalid_gzip}
    after
      :zlib.close(zlib)
    end
  end

  defp inflate(body, opts) do
    with :ok <- check_deadline(opts), do: {:ok, body}
  end

  defp inflate_limited(zlib, data, opts, size, chunks) do
    with :ok <- check_deadline(opts) do
      {status, output} = :zlib.safeInflate(zlib, data)
      output_bytes = IO.iodata_length(output)
      size = size + output_bytes

      cond do
        size > opts.max_body -> {:error, {:limit, :max_body}}
        status == :finished -> {:ok, [output | chunks]}
        output_bytes == 0 and data == <<>> -> {:error, :invalid_gzip}
        true -> inflate_limited(zlib, <<>>, opts, size, [output | chunks])
      end
    end
  end
end
