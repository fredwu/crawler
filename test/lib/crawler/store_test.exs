defmodule Crawler.StoreTest do
  use ExUnit.Case, async: false

  alias Crawler.Store

  test "a save that raises leaves the store running" do
    assert {:error, "disk"} = Store.commit("save-boom", nil, fn -> raise "disk" end)

    assert Store.ops_count("save-boom") == 0
  end
end
