defmodule Crawler.Frontier.Index do
  @moduledoc false

  defstruct classes: nil, entries: %{}, sequence: 0

  def new, do: %__MODULE__{classes: :gb_trees.empty()}
  def size(index), do: map_size(index.entries)
  def empty?(index), do: map_size(index.entries) == 0

  def put(index, id, ceiling) when is_integer(ceiling) or ceiling == :infinity do
    index = delete(index, id)
    sequence = index.sequence
    bucket = bucket(index, ceiling)
    bucket = :gb_trees.insert(sequence, id, bucket)

    %{
      index
      | classes: :gb_trees.enter(ceiling, bucket, index.classes),
        entries: Map.put(index.entries, id, {ceiling, sequence}),
        sequence: sequence + 1
    }
  end

  def delete(index, id) do
    case Map.pop(index.entries, id) do
      {nil, _entries} ->
        index

      {{ceiling, sequence}, entries} ->
        bucket = :gb_trees.delete(sequence, bucket(index, ceiling))

        classes =
          if :gb_trees.is_empty(bucket),
            do: :gb_trees.delete(ceiling, index.classes),
            else: :gb_trees.update(ceiling, bucket, index.classes)

        %{index | classes: classes, entries: entries}
    end
  end

  def eligible?(index, used), do: eligible_class(index, used) != :none

  def take(index, used) do
    case eligible_class(index, used) do
      :none ->
        :empty

      {_ceiling, bucket} ->
        {_sequence, id} = :gb_trees.smallest(bucket)
        {:ok, id, delete(index, id)}
    end
  end

  def maximum(index) do
    if empty?(index), do: nil, else: elem(:gb_trees.largest(index.classes), 0)
  end

  def minimum(index) do
    if empty?(index), do: nil, else: elem(:gb_trees.smallest(index.classes), 0)
  end

  def first_full(index, completed) do
    if empty?(index) do
      :none
    else
      {ceiling, bucket} = :gb_trees.smallest(index.classes)

      if is_integer(ceiling) and ceiling <= completed,
        do: {:ok, elem(:gb_trees.smallest(bucket), 1)},
        else: :none
    end
  end

  defp eligible_class(index, used) do
    iterator = :gb_trees.iterator_from(used + 1, index.classes)

    case :gb_trees.next(iterator) do
      :none -> :none
      {ceiling, bucket, _iterator} -> {ceiling, bucket}
    end
  end

  defp bucket(index, ceiling) do
    case :gb_trees.lookup(ceiling, index.classes) do
      :none -> :gb_trees.empty()
      {:value, bucket} -> bucket
    end
  end
end
