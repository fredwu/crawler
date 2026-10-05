defmodule Crawler.Fetcher.UrlFilter do
  @moduledoc """
  Default URL filter.

  Ordinary navigation stays on the seed site. Scripts, stylesheets, images,
  fonts, and other subresources may be fetched from another host. A custom
  `:url_filter` module replaces this decision.
  """

  alias Crawler.Site

  @navigation [nil, "a", "area", "meta"]

  defmodule Spec do
    @moduledoc """
    Defines a URL filter.

    Return `{:ok, true}` to allow a URL or `{:ok, false}` to reject it with a
    policy warning. Return `{:error, reason}` when filtering fails. The initial
    URL's error is returned unchanged by the policer, fetcher, and worker.
    The default parser logs a fixed error message without the reason.
    """

    @type url :: String.t()
    @type opts :: map

    @callback filter(url, opts) :: {:ok, boolean} | {:error, term}
  end

  @behaviour __MODULE__.Spec

  @doc """
  Whether to pass through a given URL.

  - `true` for letting the url through
  - `false` for rejecting the url
  """
  def filter(url, opts) do
    site = opts[:site]
    tag = opts[:reference_tag]

    if is_nil(site) or tag not in @navigation or Site.same_site?(site, url) do
      {:ok, true}
    else
      {:ok, false}
    end
  end
end
