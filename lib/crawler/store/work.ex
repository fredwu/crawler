defmodule Crawler.Store.Work do
  @moduledoc false

  defstruct pending: 0, inflight: 0, pages: MapSet.new()
end
