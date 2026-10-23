defmodule Crawler.Frontier.Ring do
  @moduledoc false

  defstruct order: nil, members: %{}, sequence: 0

  def new, do: %__MODULE__{order: :gb_trees.empty()}
  def size(ring), do: map_size(ring.members)

  def put(ring, id) do
    if Map.has_key?(ring.members, id) do
      ring
    else
      %{
        ring
        | order: :gb_trees.insert(ring.sequence, id, ring.order),
          members: Map.put(ring.members, id, ring.sequence),
          sequence: ring.sequence + 1
      }
    end
  end

  def delete(ring, id) do
    case Map.pop(ring.members, id) do
      {nil, _members} ->
        ring

      {sequence, members} ->
        %{ring | order: :gb_trees.delete(sequence, ring.order), members: members}
    end
  end

  def take(ring) do
    if :gb_trees.is_empty(ring.order) do
      :empty
    else
      {_sequence, id} = :gb_trees.smallest(ring.order)
      {:ok, id, delete(ring, id)}
    end
  end
end
