defmodule Crawler.Store.Page do
  @moduledoc """
  An internal struct for keeping the url and content of a crawled page.
  """

  defstruct [:url, :body, :opts, :processed]
end
