defmodule Crawler.HTTP do
  @moduledoc """
  Project-owned HTTP boundary.
  """

  def get(url, headers, opts) do
    opts
    |> Keyword.put(:url, url)
    |> Keyword.put(:headers, headers)
    |> Req.get()
  end
end
