defmodule Crawler.Store.Claims do
  @moduledoc false

  defmodule Claim do
    @moduledoc false
    defstruct [
      :worker,
      :scope,
      :generation,
      :queue,
      :primary_key,
      reserved?: true,
      aliases: MapSet.new()
    ]
  end

  defstruct active: %{}

  def track(claims, ref, worker, opts, reserved? \\ true) do
    claim = %Claim{
      worker: worker,
      scope: opts[:scope],
      generation: opts[:generation],
      queue: opts[:queue],
      primary_key: opts[:page_key],
      reserved?: reserved?
    }

    %{claims | active: Map.put(claims.active, ref, claim)}
  end

  def source_ref(claims, worker, key, queue) do
    Enum.find_value(claims.active, fn
      {ref, %Claim{worker: ^worker, primary_key: ^key, queue: ^queue, reserved?: true}} -> ref
      _ -> nil
    end)
  end

  def owned?(claims, ref, worker), do: match?(%Claim{worker: ^worker}, claims.active[ref])

  def in_use?(claims, key, worker) do
    Enum.any?(claims.active, fn {_ref, claim} ->
      claim.worker != worker and
        (claim.primary_key === key or MapSet.member?(claim.aliases, key))
    end)
  end

  def add_alias(claims, worker, {_url, scope} = key, queue) do
    update_aliases(claims, worker, scope, queue, &MapSet.put(&1, key))
  end

  def delete_alias(claims, worker, {_url, scope} = key, queue) do
    update_aliases(claims, worker, scope, queue, &MapSet.delete(&1, key))
  end

  defp update_aliases(claims, worker, scope, queue, update) do
    active =
      Map.new(claims.active, fn
        {ref, %Claim{worker: ^worker, scope: ^scope, queue: ^queue} = claim} ->
          {ref, %{claim | aliases: update.(claim.aliases)}}

        entry ->
          entry
      end)

    %{claims | active: active}
  end

  def take(claims, ref, worker) do
    case claims.active[ref] do
      %Claim{worker: ^worker} = claim ->
        {claim, %{claims | active: Map.delete(claims.active, ref)}}

      _ ->
        {nil, claims}
    end
  end

  def retire_scope(claims, scope), do: retire(claims, &(&1.scope === scope))
  def retire_queue(claims, queue), do: retire(claims, &(&1.queue == queue))

  defp retire(claims, match?) do
    {removed, kept} = Enum.split_with(claims.active, fn {_ref, claim} -> match?.(claim) end)
    {Enum.map(removed, &elem(&1, 0)), %{claims | active: Map.new(kept)}}
  end
end
