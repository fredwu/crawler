defmodule Crawler.Fetcher.PolicerTest do
  use Crawler.TestCase, async: true

  alias Crawler.Fetcher.{Policer, UrlFilter}

  doctest Policer
end
