defmodule Crawler.ParserTest do
  use Crawler.TestCase, async: true

  alias Crawler.{Parser, Store.Page}

  doctest Parser

  def image_file do
    {:ok, file} = File.read("test/fixtures/introducing-elixir.jpg")
    file
  end
end
