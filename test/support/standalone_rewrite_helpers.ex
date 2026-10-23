defmodule Crawler.StandaloneRewriteHelpers do
  @moduledoc false

  alias Crawler.Analysis
  alias Crawler.Parser
  alias Crawler.Snapper.LinkReplacer

  def replace_bound(source, opts, select_target, outcomes) do
    with {:ok, prepared} <- Parser.prepare_for_parse(source, opts),
         {:ok, bound} <- LinkReplacer.bind_prepared(prepared, select_target) do
      LinkReplacer.replace_prepared(bound, fn occurrence ->
        case Map.fetch(outcomes, occurrence.target) do
          {:ok, {:ok, path}} -> {:local, path}
          {:ok, {:error, _reason}} -> Analysis.online_fallback(occurrence)
          :error -> Analysis.online_fallback(occurrence)
        end
      end)
    end
  end
end
