defmodule Crawler.Options do
  @moduledoc """
  Options for the crawler.
  """

  alias Crawler.Mixfile

  @max_depths 3
  @workers    10
  @interval   0
  @timeout    5_000
  @user_agent "Crawler/#{Mixfile.project[:version]} (https://github.com/fredwu/crawler)"
  @save_to    nil
  @assets     []
  @retrier    Crawler.Fetcher.Retrier
  @url_filter Crawler.Fetcher.UrlFilter
  @parser     Crawler.Parser

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
    Map.merge(%{
      depth:      0,
      html_tag:   "a",
      max_depths: max_depths(),
      workers:    workers(),
      interval:   interval(),
      timeout:    timeout(),
      user_agent: user_agent(),
      save_to:    save_to(),
      assets:     assets(),
      retrier:    retrier(),
      url_filter: url_filter(),
      parser:     parser(),
    }, opts)
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
  def assign_url(opts, url) do
    Map.merge(opts, %{url: url})
  end

  defp max_depths, do: Application.get_env(:crawler, :max_depths, @max_depths)
  defp workers,    do: Application.get_env(:crawler, :workers,    @workers)
  defp interval,   do: Application.get_env(:crawler, :interval,   @interval)
  defp timeout,    do: Application.get_env(:crawler, :timeout,    @timeout)
  defp user_agent, do: Application.get_env(:crawler, :user_agent, @user_agent)
  defp save_to,    do: Application.get_env(:crawler, :save_to,    @save_to)
  defp assets,     do: Application.get_env(:crawler, :assets,     @assets)
  defp retrier,    do: Application.get_env(:crawler, :retrier,    @retrier)
  defp url_filter, do: Application.get_env(:crawler, :url_filter, @url_filter)
  defp parser,     do: Application.get_env(:crawler, :parser,     @parser)
end
