defmodule Crawler.Options do
  @moduledoc """
  Options for the crawler.
  """

  alias Crawler.Mixfile

  @assets     []
  @save_to    nil
  @workers    10
  @interval   0
  @max_depths 3
  @timeout    5_000
  @user_agent "Crawler/#{Mixfile.project[:version]} (https://github.com/fredwu/crawler)"
  @url_filter Crawler.Fetcher.UrlFilter
  @retrier    Crawler.Fetcher.Retrier
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
      assets:     assets(),
      save_to:    save_to(),
      workers:    workers(),
      interval:   interval(),
      max_depths: max_depths(),
      timeout:    timeout(),
      user_agent: user_agent(),
      url_filter: url_filter(),
      retrier:    retrier(),
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

  defp assets,     do: Application.get_env(:crawler, :assets,     @assets)
  defp save_to,    do: Application.get_env(:crawler, :save_to,    @save_to)
  defp workers,    do: Application.get_env(:crawler, :workers,    @workers)
  defp interval,   do: Application.get_env(:crawler, :interval,   @interval)
  defp max_depths, do: Application.get_env(:crawler, :max_depths, @max_depths)
  defp timeout,    do: Application.get_env(:crawler, :timeout,    @timeout)
  defp user_agent, do: Application.get_env(:crawler, :user_agent, @user_agent)
  defp url_filter, do: Application.get_env(:crawler, :url_filter, @url_filter)
  defp retrier,    do: Application.get_env(:crawler, :retrier,    @retrier)
  defp parser,     do: Application.get_env(:crawler, :parser,     @parser)
end
