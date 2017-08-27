defmodule Crawler.Store do
  @moduledoc """
  An internal data store for information related to each crawl.
  """

  alias __MODULE__.DB

  defmodule Page do
    @moduledoc """
    An internal struct for keeping the url and content of a crawled page.
    """

    defstruct [:url, :body, :processed]
  end

  def init do
    Registry.start_link(keys: :unique, name: DB)
  end

  def find(url) do
    case Registry.lookup(DB, url) do
      [{_, page}] -> page
      _           -> nil
    end
  end

  def find_processed(url) do
    case Registry.match(DB, url, %{processed: true}) do
      [{_, page}] -> page
      _           -> nil
    end
  end

  def add(url) do
    Registry.register(DB, url, %Page{url: url})
  end

  def add_body(url, body) do
    {_new, _old} = Registry.update_value(DB, url, & %{&1 | body: body})
  end

  def processed(url) do
    {_new, _old} = Registry.update_value(DB, url, & %{&1 | processed: true})
  end
end
