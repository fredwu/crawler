defmodule Crawler.Store do
  alias Crawler.Store.DB

  defmodule Page do
    defstruct [:url, :body, :processed]
  end

  def init do
    Registry.start_link(keys: :unique, name: DB)
  end

  def find(url) do
    case Registry.lookup(DB, url) do
      [{_, page}] -> page
      _           -> false
    end
  end

  def find_processed(url) do
    case Registry.match(DB, url, %{processed: true}) do
      [{_, page}] -> page
      _           -> false
    end
  end

  def add(url, body) do
    Registry.register(DB, url, %Page{url: url, body: body})

    %Page{url: url, body: body}
  end

  def processed(url) do
    Registry.update_value(DB, url, &(%{&1 | processed: true}))
  end
end
