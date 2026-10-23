defmodule Crawler.Frontier.IndexTest do
  use ExUnit.Case, async: true

  alias Crawler.Frontier.Index
  alias Crawler.Frontier.Ring

  test "eligibility skips a blocked class and keeps FIFO within each ceiling" do
    index = Index.new() |> Index.put(:small, 1) |> Index.put(:first, 3) |> Index.put(:second, 3)
    assert {:ok, :first, index} = Index.take(index, 1)
    assert {:ok, :second, index} = Index.take(index, 1)
    assert :empty = Index.take(index, 1)
    assert {:ok, :small, index} = Index.take(index, 0)
    assert Index.empty?(index)
  end

  test "deleting arbitrary work does not retain queue tombstones" do
    index = Enum.reduce(1..2_000, Index.new(), &Index.put(&2, &1, rem(&1, 7) + 1))
    index = Enum.reduce(1..2_000, index, &Index.delete(&2, &1))
    assert Index.size(index) == 0
    assert :gb_trees.is_empty(index.classes)
    assert :empty = Index.take(index, 0)
  end

  test "infinite ceilings remain eligible and full detection is indexed" do
    index = Index.new() |> Index.put(:full, 1) |> Index.put(:unlimited, :infinity)
    assert Index.maximum(index) == :infinity
    assert Index.first_full(index, 1) == {:ok, :full}
    assert {:ok, :unlimited, index} = Index.take(index, 10_000)
    assert Index.first_full(index, 0) == :none
  end

  test "the ring rotates current scopes without duplicate or retired entries" do
    ring = Ring.new() |> Ring.put(:one) |> Ring.put(:two) |> Ring.put(:one)
    assert Ring.size(ring) == 2
    assert {:ok, :one, ring} = Ring.take(ring)
    ring = Ring.put(ring, :one)
    assert {:ok, :two, ring} = Ring.take(ring)
    assert {:ok, :one, ring} = Ring.take(ring)
    assert Ring.take(ring) == :empty
  end
end
