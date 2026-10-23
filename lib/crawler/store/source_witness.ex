defmodule Crawler.Store.SourceWitness do
  @moduledoc false

  alias Crawler.Fetcher.HeaderPreparer
  alias Crawler.Store.Authority
  alias Crawler.Store.ResourceManager
  alias Crawler.Store.Resources
  alias Crawler.Store.Retained

  def physical(response, opts) do
    if Authority.export_managed?(opts.scope, opts.generation) do
      headers = HeaderPreparer.prepare(Req.get_headers_list(response), %{})
      url = Req.Response.get_private(response, :crawler_url) || opts.url

      witness = %{
        revision: Req.Response.get_private(response, :crawler_source_revision),
        digest: :crypto.hash(:sha256, response.body || <<>>),
        bytes: byte_size(response.body || <<>>),
        content_type: headers.content_type,
        final_url: Crawler.URL.normalize(url)
      }

      Req.Response.put_private(response, :crawler_source_witness, witness)
    else
      response
    end
  end

  def remember(state, lease, response) do
    execution = state.executions[lease]

    execution =
      execution
      |> Map.put(:source_revision, Req.Response.get_private(response, :crawler_source_revision))
      |> Map.put(:physical_final_url, Req.Response.get_private(response, :crawler_url))
      |> Map.put(:physical_witness, Req.Response.get_private(response, :crawler_source_witness))

    %{state | executions: Map.put(state.executions, lease, execution)}
  end

  def validate_registration(execution, plan, content_type, final_url) do
    with :ok <- validate_existing(execution, plan, content_type, final_url),
         true <- plan.root_ownership === :borrowed or {:error, :source_witness_mismatch},
         do: :ok
  end

  def validate_existing(execution, plan, content_type, final_url) do
    with %{revision: revision, content_type: ^content_type, final_url: ^final_url} = physical <-
           execution[:physical_witness],
         true <- plan.source_revision === revision,
         {:ok, expected} <- expected(execution[:decoded_witness], physical),
         true <- plan.digest === expected.digest and plan.bytes === expected.bytes,
         true <- plan.root_ownership in [:borrowed, :retained] do
      :ok
    else
      _ -> {:error, :source_witness_mismatch}
    end
  end

  defp expected(%{revision: revision} = decoded, %{revision: revision}), do: {:ok, decoded}

  defp expected(nil, physical) do
    type = physical.content_type

    if Crawler.MediaType.text?(type) or Crawler.MediaType.javascript?(type) or
         Crawler.MediaType.document_mode(type) == :xml,
       do: {:error, :missing_decoded_witness},
       else: {:ok, physical}
  end

  defp expected(_, _), do: {:error, :missing_decoded_witness}

  def record(state, opts, witness, receipt, worker) do
    lease = opts.execution_lease
    execution = state.executions[lease]

    with %{worker: ^worker, arena: arena, physical_witness: %{revision: revision}} <- execution,
         true <- revision === opts.source_revision,
         true <- valid?(witness, revision, opts),
         %{kind: :response, actual: bytes, copy_bytes: copy, holders: holders}
         when is_integer(bytes) and is_integer(copy) <-
           Resources.receipt(state.resources, receipt),
         %{status: :pending, lease: ^lease, arena: ^arena, origin: ^worker} <- holders[self()],
         true <- Authority.resource_current?(receipt, lease, self()),
         {:ok, _} <- Retained.bytes(witness, bytes),
         {:ok, _} <- Retained.copy_bytes(witness, copy) do
      case ResourceManager.transition(state, Resources.adopt(state.resources, receipt, self())) do
        {:ok, state} ->
          state = clear_decoded(state, lease)
          execution = state.executions[lease]
          execution = Map.merge(execution, %{decoded_witness: witness, witness_receipt: receipt})

          {:ok,
           %{
             state
             | executions: Map.put(state.executions, lease, execution),
               persistent_resources: MapSet.put(state.persistent_resources, receipt)
           }}

        {error, state} ->
          {error, state}
      end
    else
      _ -> {{:error, :invalid_source_witness}, state}
    end
  end

  defp valid?(
         %{
           revision: revision,
           digest: digest,
           bytes: bytes,
           decoder_seed: %Crawler.Analysis.Budget{} = seed,
           root_ownership: :borrowed
         } = witness,
         revision,
         opts
       )
       when map_size(witness) == 5 and is_binary(digest) and byte_size(digest) == 32 and
              is_integer(bytes) and bytes >= 0 and bytes <= opts.max_body do
    Crawler.Store.SourceManager.validate_decoder(
      "",
      %{budget: seed, unavailable: seed.retained},
      :borrowed,
      Crawler.Limits.analysis(opts)
    ) == :ok
  end

  defp valid?(_, _, _), do: false

  def clear(state, lease) do
    state = clear_decoded(state, lease)

    execution =
      Map.merge(state.executions[lease], %{
        source_revision: nil,
        physical_witness: nil,
        physical_final_url: nil
      })

    %{state | executions: Map.put(state.executions, lease, execution)}
  end

  def clear_decoded(state, lease) do
    execution = state.executions[lease]

    if receipt = execution[:witness_receipt] do
      send(self(), {:release_source_witness, receipt})
      execution = Map.merge(execution, %{decoded_witness: nil, witness_receipt: nil})

      %{
        state
        | executions: Map.put(state.executions, lease, execution),
          persistent_resources: MapSet.delete(state.persistent_resources, receipt)
      }
    else
      state
    end
  end
end
