defmodule Crawler.SnapperTest do
  use Crawler.TestCase, async: true

  alias Crawler.Snapper

  @moduletag capture_log: true

  doctest Snapper
end
