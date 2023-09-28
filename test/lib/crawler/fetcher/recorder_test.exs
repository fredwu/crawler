defmodule Crawler.Fetcher.RecorderTest do
  use Crawler.TestCase, async: true

  alias Crawler.Fetcher.Recorder
  alias Crawler.Store
  alias Crawler.Store.Page

  doctest Recorder
end
