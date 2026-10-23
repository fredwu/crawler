defmodule Crawler.HTTP.BodyLimitExceeded do
  @moduledoc false

  defexception [:key, :limit, :reason]

  @impl true
  def message(%{key: key, limit: limit}), do: "response exceeded #{key} limit of #{limit}"
end
