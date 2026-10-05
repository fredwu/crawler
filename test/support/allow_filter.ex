defmodule Crawler.AllowFilter do
  @moduledoc false

  @behaviour Crawler.Fetcher.UrlFilter.Spec

  def filter(_url, _opts), do: {:ok, true}
end
