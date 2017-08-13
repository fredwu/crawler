defmodule Crawler.Dispatcher.Worker do
  @moduledoc """
  A worker that performs the crawling.
  """

  def start_link(opts) do
    Task.start_link fn ->
      Crawler.crawl_now(opts)
    end
  end
end
