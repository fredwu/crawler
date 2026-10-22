defmodule Crawler.HeldParser do
  @moduledoc false

  alias Crawler.Parser
  alias Crawler.Store.Page

  def parse(%Page{url: url, opts: %{hold_parser_url: url, parser_observer: observer}} = page) do
    send(observer, {:parser_held, self(), page})

    receive do
      :release_parser -> Parser.parse(page)
      {:release_parser, replacement} -> {:ok, replacement}
    end
  end

  def parse(input), do: Parser.parse(input)
end
