defmodule Crawler.Fetcher.AliasSettlement do
  @moduledoc false

  alias Crawler.Fetcher.Recorder
  alias Crawler.Snapper
  alias Crawler.Store

  defstruct [:ref, :queue]

  def run(%__MODULE__{ref: ref}) do
    case Store.start_settlement(ref) do
      {:ok, token, body, opts} ->
        try do
          with {:ok, _} <- Recorder.maybe_store_page(body, opts),
               {:ok, _} <- save(body, opts) do
            Store.complete_settlement(ref, token)
          end
        after
          Store.finish_claim(token)
        end

      :skip ->
        :ok
    end
  end

  defp save(body, %{save_to: root} = opts) when is_binary(root), do: Snapper.snap(body, opts)
  defp save(_body, opts), do: {:ok, opts}
end
