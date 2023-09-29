defmodule Crawler.Fetcher.RequesterTest do
  use Crawler.TestCase, async: true

  alias Crawler.Fetcher.Requester

  @moduletag capture_log: true

  doctest Requester
end
