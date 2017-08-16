defmodule Crawler.Options do
  @moduledoc """
  Options for the crawler.
  """

  @max_depths 3
  @workers    10
  @interval   0
  @timeout    5_000
  @save_to    nil
  @parser     Crawler.Parser

  @doc """
  ## Examples

      iex> Options.assign_defaults([]) |> Keyword.has_key?(:depth)
      true

      iex> Options.assign_defaults([]) |> Keyword.get(:max_depths)
      3

      iex> Options.assign_defaults([max_depths: 4]) |> Keyword.get(:max_depths)
      4
  """
  def assign_defaults(opts) do
    Keyword.merge([
      depth:      0,
      max_depths: max_depths(),
      workers:    workers(),
      interval:   interval(),
      timeout:    timeout(),
      save_to:    save_to(),
      parser:     parser(),
    ], opts)
  end

  @doc """
  ## Examples

      iex> Options.assign_url([], "http://options/")
      [url: "http://options/"]

      iex> Options.assign_url([url: "http://example.com/"], "http://options/")
      [url: "http://options/"]
  """
  def assign_url(opts, url) do
    Keyword.merge(opts, [url: url])
  end

  defp max_depths, do: Application.get_env(:crawler, :max_depths) || @max_depths
  defp workers,    do: Application.get_env(:crawler, :workers)    || @workers
  defp interval,   do: Application.get_env(:crawler, :interval)   || @interval
  defp timeout,    do: Application.get_env(:crawler, :timeout)    || @timeout
  defp save_to,    do: Application.get_env(:crawler, :save_to)    || @save_to
  defp parser,     do: Application.get_env(:crawler, :parser)     || @parser
end
