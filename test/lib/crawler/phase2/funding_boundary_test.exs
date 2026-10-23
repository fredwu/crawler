defmodule Crawler.Phase2.FundingBoundaryTest do
  use ExUnit.Case, async: false

  alias Crawler.Export.StagedIO
  alias Crawler.Store
  alias Crawler.Store.Execution

  test "funding exports only current bounded grant proofs without exposing the ledger" do
    scope = make_ref()
    on_exit(fn -> Store.dispose_scope(scope) end)

    assert :ok =
             Execution.run(%{scope: scope}, fn opts ->
               assert {:ok, retained} = Store.reserve_resource(opts, :analysis, 1_024)
               assert {:ok, overlap} = Store.reserve_resource(opts, :snapshot, 2_048)
               credit = %{retained: [retained], backing: [], overlap: overlap, unavailable: 17}
               before = :sys.get_state(Store).resources
               assert {:ok, %StagedIO.Funding{} = funding} = Store.resource_funding(opts, credit)
               assert funding.retained_capacity == 1_024
               assert funding.overlap_capacity == 2_048
               assert funding.unavailable == 17
               assert Map.keys(funding.grants) |> Enum.sort() == Enum.sort([retained, overlap])
               assert :sys.get_state(Store).resources == before

               assert {:error, :stale} =
                        Store.resource_funding(Map.put(opts, :generation, make_ref()), credit)

               assert {:error, :stale} =
                        Store.resource_funding(
                          Map.put(opts, :execution_lease, make_ref()),
                          credit
                        )

               :ok
             end)
  end
end
