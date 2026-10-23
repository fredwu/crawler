defmodule Crawler.Parser.Prepared do
  @moduledoc false

  @enforce_keys [:source, :opts, :occurrences, :groups]
  defstruct [
    :source,
    :analysis,
    :opts,
    :occurrences,
    :collection,
    :css_collection,
    :css_revision,
    :groups,
    :callback_members,
    :source_revision,
    :analysis_revision,
    :context_key
  ]
end
