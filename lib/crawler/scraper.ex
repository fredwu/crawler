defmodule Crawler.Scraper do
  @moduledoc """
  A placeholder module that demonstrates the scraping interface.
  """

  defmodule Spec do
    @moduledoc """
    Spec for defining a scraper.
    """

    alias Crawler.Store.Page

    @type url  :: String.t
    @type body :: String.t
    @type opts :: map
    @type page :: %Page{url: url, body: body, opts: opts}

    @callback scrape(page) :: {:ok, page}
  end

  @behaviour __MODULE__.Spec

  alias Crawler.Store.Page

  @doc """
  """
  def scrape(%Page{url: _url, body: _body, opts: _opts} = page), do: {:ok, page}
end
