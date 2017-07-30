defmodule Crawler.Fetcher.PolicerTest do
  use Crawler.TestCase, async: true

  alias Crawler.Fetcher.Policer

  doctest Policer, import: true

  def url, do: "http://localhost/"
end
