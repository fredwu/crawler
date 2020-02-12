defmodule Crawler.Store do
  @moduledoc """
  An internal data store for information related to each crawl.
  include the ets in a gen_server in order for it to be garbage collected.
  However don't go through the process to access it, for the process to not
  be a bottleneck.
  """
  use GenServer
  @table :db

  @type url :: String.t

  defmodule Page do
    @moduledoc """
    An internal struct for keeping the url and content of a crawled page.
    """

    defstruct [:url, :body, :opts, :processed]
  end

  @doc """
  Initialises a new `Registry` named `Crawler.Store.DB`.
  """
  def start_link do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def init(nil) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, nil}
  end

  @doc """
  Finds a stored URL and returns its page data.
  """
  @spec find(url) :: %Page{} | nil
  def find(url) do
    case :ets.lookup(@table, url) do
      [{_, page}] -> page
      _           -> nil
    end
  end

  @doc """
  Finds a stored URL and returns its page data only if it's processed.
  """
  @spec find_processed(url) :: %Page{} | nil
  def find_processed(url) do
    case :ets.match_object(@table, {url, %{processed: true}}) do
      [{_, page}] -> page
      _           -> nil
    end
  end

  @doc """
  Adds a URL to the registry.
  """
  @spec add(url) :: {:ok, boolean}
  def add(url) do
    {:ok, :ets.insert_new(@table, {url, %Page{url: url}})}
  end

  @spec update(url, map) :: boolean
  defp update(url, args) do
    case find(url) do
      nil -> false
      page ->
        page
        |> Map.merge(args)
        |> update!()
    end
  end

  @spec update!(%Page{}) :: boolean
  defp update!(page) do
    :ets.insert(@table, {page.url, page})
  end

  @doc """
  Adds the page data for a URL to the registry.
  """
  def add_page_data(url, body, opts), do: update(url, %{body: body, opts: opts})

  @doc """
  Marks a URL as processed in the registry.
  """
  def processed(url), do: update(url, %{processed: true})
end
