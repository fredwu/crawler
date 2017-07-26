defmodule Crawler.Store do
  defmodule Page do
    defstruct [:url, :body]
  end

  def init do
    Registry.start_link(keys: :unique, name: Crawler.Store.DB)
  end

  def add(url, body) do
    Registry.register(Crawler.Store.DB, url, %Page{url: url, body: body})

    %Page{url: url, body: body}
  end

  def find(url) do
    [{_, page}] = Registry.lookup(Crawler.Store.DB, url)

    page
  end
end
