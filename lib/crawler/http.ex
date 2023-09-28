defmodule Crawler.HTTP do
  @moduledoc """
  Custom Tesla base module for potential customisation.
  """

  use Tesla

  plug(Tesla.Middleware.FollowRedirects)
end
