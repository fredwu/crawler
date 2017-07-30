defmodule Crawler.Worker.ParserTest do
  use Crawler.TestCase, async: true

  alias Crawler.{Worker.Parser, Store.Page}

  doctest Parser
end
