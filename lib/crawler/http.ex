defmodule Crawler.HTTP do
  use HTTPoison.Base

  alias Crawler.Mixfile

  @default_ua "Crawler/#{Mixfile.project[:version]} (https://github.com/fredwu/crawler)"

  def process_request_headers(headers) do
    Keyword.merge(headers, ["User-Agent": @default_ua])
  end
end
