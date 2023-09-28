defmodule Crawler.Fetcher.PolicerTest do
  use Crawler.TestCase, async: true

  alias Crawler.Fetcher.Policer
  alias Crawler.Fetcher.UrlFilter

  doctest Policer
end
