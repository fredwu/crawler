defmodule Crawler.Options do
  @moduledoc """
  Options for the crawler.
  """

  alias Crawler.Mixfile
  alias Crawler.Store

  @assets []
  @save_to nil
  @workers 10
  @interval 0
  @max_depths 3
  @max_pages :infinity
  @timeout 5_000
  @retries 2
  @store nil
  @force false
  @scope nil
  @user_agent "Crawler/#{Mixfile.project()[:version]} (https://github.com/fredwu/crawler)"
  @url_filter Crawler.Fetcher.UrlFilter
  @retrier Crawler.Fetcher.Retrier
  @modifier Crawler.Fetcher.Modifier
  @scraper Crawler.Scraper
  @parser Crawler.Parser
  @encode_uri false
  @queue nil

  @doc """
  Assigns default option values.

  ## Examples

      iex> Options.assign_defaults(%{}) |> Map.has_key?(:depth)
      true

      iex> Options.assign_defaults(%{}) |> Map.get(:max_depths)
      3

      iex> Options.assign_defaults(%{max_depths: 4}) |> Map.get(:max_depths)
      4
  """
  def assign_defaults(opts) do
    Map.merge(
      %{
        depth: 0,
        html_tag: "a",
        assets: assets(),
        save_to: save_to(),
        workers: workers(),
        interval: interval(),
        max_depths: max_depths(),
        max_pages: max_pages(),
        timeout: timeout(),
        retries: retries(),
        store: store(),
        force: force(),
        scope: scope(),
        user_agent: user_agent(),
        url_filter: url_filter(),
        retrier: retrier(),
        modifier: modifier(),
        scraper: scraper(),
        parser: parser(),
        encode_uri: encode_uri(),
        queue: queue()
      },
      opts
    )
  end

  @doc """
  Takes the `url` argument and puts it in the `opts`.

  The `opts` map gets passed around internally and eventually gets stored in
  the registry.

  ## Examples

      iex> Options.assign_url(%{}, "http://options/")
      %{url: "http://options/"}

      iex> Options.assign_url(%{url: "http://example.com/"}, "http://options/")
      %{url: "http://options/"}
  """
  def assign_url(%{encode_uri: true} = opts, url) do
    Map.merge(opts, %{url: URI.encode(url)})
  end

  def assign_url(opts, url) do
    Map.merge(opts, %{url: url})
  end

  def assign_scope(%{force: true, scope: nil} = opts) do
    Map.merge(opts, %{scope: System.unique_integer()})
  end

  def assign_scope(opts), do: opts

  def perform_default_actions(%{depth: 0} = opts) do
    Store.ops_reset()

    opts
  end

  def perform_default_actions(opts), do: opts

  defp assets, do: Application.get_env(:crawler, :assets, @assets)
  defp save_to, do: Application.get_env(:crawler, :save_to, @save_to)
  defp workers, do: Application.get_env(:crawler, :workers, @workers)
  defp interval, do: Application.get_env(:crawler, :interval, @interval)
  defp max_depths, do: Application.get_env(:crawler, :max_depths, @max_depths)
  defp max_pages, do: Application.get_env(:crawler, :max_pages, @max_pages)
  defp timeout, do: Application.get_env(:crawler, :timeout, @timeout)
  defp retries, do: Application.get_env(:crawler, :retries, @retries)
  defp store, do: Application.get_env(:crawler, :store, @store)
  defp force, do: Application.get_env(:crawler, :force, @force)
  defp scope, do: Application.get_env(:crawler, :scope, @scope)
  defp user_agent, do: Application.get_env(:crawler, :user_agent, @user_agent)
  defp url_filter, do: Application.get_env(:crawler, :url_filter, @url_filter)
  defp retrier, do: Application.get_env(:crawler, :retrier, @retrier)
  defp modifier, do: Application.get_env(:crawler, :modifier, @modifier)
  defp scraper, do: Application.get_env(:crawler, :scraper, @scraper)
  defp parser, do: Application.get_env(:crawler, :parser, @parser)
  defp encode_uri, do: Application.get_env(:crawler, :encode_uri, @encode_uri)
  defp queue, do: Application.get_env(:crawler, :queue, @queue)
end
