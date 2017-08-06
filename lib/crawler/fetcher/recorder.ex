defmodule Crawler.Fetcher.Recorder do
  @moduledoc """
  Records information about each crawl for internal use.
  """

  alias Crawler.Store

  @doc """
  ## Examples

      iex> Recorder.record(url: "url1", depth: 2)
      {:ok, [depth: 3, url: "url1"]}

      iex> Recorder.record(url: "url2", depth: 2)
      iex> Store.find("url2")
      %Page{url: "url2"}
  """
  def record(opts) do
    with {:ok, _pid} <- store_url(opts),
         opts        <- store_url_depth(opts)
    do
      {:ok, opts}
    end
  end

  def store_page(url, body) do
    {:ok, Store.add_body(url, body)}
  end

  defp store_url(opts) do
    Store.add(opts[:url])
  end

  defp store_url_depth(opts) do
    Keyword.replace(opts, :depth, opts[:depth] + 1)
  end
end
