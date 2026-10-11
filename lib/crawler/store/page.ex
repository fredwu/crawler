defmodule Crawler.Store.Page do
  @moduledoc """
  An internal struct for keeping the url and content of a crawled page.

  `fetch_tag` is the reference role of the fetch that first registered the URL.
  Registrations that are not fetches leave it empty.

  `picture_type` is the content type of a fetch that is not a document. It stays
  empty until that response identifies itself. Document fetches leave it empty.
  """

  defstruct [:url, :body, :opts, :processed, fetch_tag: nil, picture_type: nil]
end
