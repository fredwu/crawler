defmodule Crawler.Store.Scope do
  @moduledoc false

  defstruct ops: 0, revision: nil, work: %{}

  def new, do: %__MODULE__{revision: make_ref()}
end
