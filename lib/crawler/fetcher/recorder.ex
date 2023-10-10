defmodule Crawler.Fetcher.Recorder do
  @moduledoc """
  Records information about each crawl for internal use.
  """

  alias Crawler.Store

  @doc """
  Records information about each crawl for internal use.

  ## Examples

      iex> Recorder.record(url: "url1", depth: 2)
      {:ok, %{depth: 3, url: "url1"}}

      iex> Recorder.record(url: "url2", depth: 2)
      iex> Store.find({"url2", nil})
      %Page{url: "url2"}
  """
  def record(opts) do
    with opts <- Enum.into(opts, %{}),
         {:ok, _pid} <- store_url(opts),
         opts <- store_url_depth(opts),
         _ <- Store.ops_inc() do
      {:ok, opts}
    end
  end

  @doc """
  Stores page data in `Crawler.Store.DB` for internal or external consumption, if enabled.

  ## Examples

      iex> Recorder.maybe_store_page("body", %{store: nil})
      {:ok, nil}

      iex> Recorder.record(url: "url", depth: 2)
      iex> Recorder.maybe_store_page("body", %{store: Store, url: "url", scope: nil})
      {:ok, {%Page{url: "url", body: "body", opts: %{store: Store, url: "url", scope: nil}}, %Page{url: "url", body: nil}}}
  """
  def maybe_store_page(_body, %{store: nil} = _opts) do
    {:ok, nil}
  end

  def maybe_store_page(body, opts) do
    {:ok, opts[:store].add_page_data({opts[:url], opts[:scope]}, body, opts)}
  end

  defp store_url(opts) do
    Store.add({opts[:url], opts[:scope]})
  end

  defp store_url_depth(opts) do
    Map.replace!(opts, :depth, opts[:depth] + 1)
  end
end
