defmodule Crawler.HTTP.DeadlineExceeded do
  @moduledoc false

  defexception [:kind, :reason]

  @impl true
  def message(%{kind: kind}), do: "#{kind} deadline exceeded"
end
