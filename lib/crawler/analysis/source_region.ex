defmodule Crawler.Analysis.SourceRegion do
  @moduledoc false

  @enforce_keys [:id, :kind, :source]
  defstruct [:id, :kind, :source, :parent, :span, :mapping, :facts, children: [], metadata: %{}]
end
