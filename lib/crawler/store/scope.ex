defmodule Crawler.Store.Scope do
  @moduledoc false

  defstruct ops: 0,
            control_documents: 0,
            control_bytes: 0,
            revision: nil,
            cookie_revision: nil,
            work: %{},
            run_deadline: nil,
            run_timer: nil,
            outcome: :open,
            reported_limit: nil

  def new, do: %__MODULE__{revision: make_ref(), cookie_revision: make_ref()}
end
