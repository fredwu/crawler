defmodule Crawler.Fetcher.RecorderTest do
  use Crawler.TestCase, async: true

  alias Crawler.{Fetcher.Recorder, Store, Store.Page}

  doctest Recorder
end
