defmodule Crawler.Fetcher.Recorder do
  alias Crawler.Store

  @doc """
  ## Examples

      iex> Recorder.record(url: "url1", level: 2)
      {:ok, [level: 3, url: "url1"]}

      iex> Recorder.record(url: "url2", level: 2)
      iex> Store.find("url2")
      %Page{url: "url2"}
  """
  def record(opts) do
    with {:ok, _pid} <- store_url(opts),
         opts        <- store_url_level(opts)
    do
      {:ok, opts}
    end
  end

  def store_page(url, body) do
    Store.add_body(url, body)
  end

  defp store_url(opts) do
    Store.add(opts[:url])
  end

  defp store_url_level(opts) do
    Keyword.replace(opts, :level, opts[:level] + 1)
  end
end
