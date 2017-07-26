defmodule Crawler.Store do
  alias Crawler.Store.DB

  defmodule Page do
    defstruct [:url, :body]
  end

  def init do
    Registry.start_link(keys: :unique, name: DB)
  end

  def add(url, body) do
    Registry.register(DB, url, %Page{url: url, body: body})

    %Page{url: url, body: body}
  end

  def find(url) do
    [{_, page}] = Registry.lookup(DB, url)

    page
  end
end
