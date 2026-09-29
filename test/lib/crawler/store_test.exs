defmodule Crawler.StoreTest do
  use ExUnit.Case, async: false

  alias Crawler.Store

  test "a save that raises leaves the store running" do
    assert {:error, "disk"} = Store.commit("save-boom", nil, fn -> raise "disk" end)

    assert Store.ops_count("save-boom") == 0
  end

  test "a slow save does not block another scope" do
    parent = self()
    scope = scope("slow-commit")
    other = scope("other-commit")

    task =
      Task.async(fn ->
        Store.commit(scope, nil, fn ->
          send(parent, :entered)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :entered, 1_000

    claim = Task.async(fn -> Store.try_claim(other, 5, nil) end)

    try do
      assert :ok = Task.await(claim, 200)
    after
      send(task.pid, :release)
    end

    assert :ok = Task.await(task)
    assert :ok = Store.inflight_dec(other)
  end

  test "a dropped scope keeps its generation" do
    scope = scope("generation")

    assert Store.generation(scope) == 0
    assert Store.drop_scope(scope) == 1
    assert Store.generation(scope) == 1
    assert Store.try_claim(scope, 1, 0) == :stale
    assert Store.try_claim(scope, 1, 1) == :ok
    assert :ok = Store.finish_work(scope, 1, true)
    assert Store.inflight_count(scope) == 0
  end

  test "a stale publish leaves the newer file and removes the old temp" do
    scope = scope("publish")
    dir = Path.join(System.tmp_dir!(), "crawler-publish-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    dest = Path.join(dir, "page.html")
    new_temp = Path.join(dir, "new.tmp")
    old_temp = Path.join(dir, "old.tmp")
    File.write!(new_temp, "NEW")
    File.write!(old_temp, "OLD")

    new_gen = Store.drop_scope(scope)
    assert :ok = Store.publish_file(scope, new_gen, dest, new_temp)
    assert {:error, :stale} = Store.publish_file(scope, new_gen - 1, dest, old_temp)

    assert File.read!(dest) == "NEW"
    refute File.exists?(old_temp)
    refute File.exists?(new_temp)
  end

  test "an idle scope drops failed pages and keeps processed pages" do
    scope = scope("sweep")
    generation = Store.generation(scope)

    assert :ok = Store.note_enqueued(scope, generation, nil)
    assert :ok = Store.note_enqueued(scope, generation, nil)
    assert {:ok, _} = Store.add({"http://kept.example", scope}, generation)
    Store.processed({"http://kept.example", scope}, generation)
    assert {:ok, _} = Store.add({"http://dropped.example", scope}, generation)

    assert :ok = Store.finish_work(scope, generation, false)
    assert Store.find({"http://dropped.example", scope})

    assert :ok = Store.finish_work(scope, generation, false)
    refute Store.find({"http://dropped.example", scope})
    assert Store.find({"http://kept.example", scope})
  end

  test "abandoning a scope keeps stored pages and releases its slots" do
    scope = scope("abandon")
    generation = Store.generation(scope)

    assert :ok = Store.ops_inc(scope, generation)
    assert {:ok, _} = Store.add({"http://kept.example/abandon", scope}, generation)
    Store.processed({"http://kept.example/abandon", scope}, generation)
    assert {:ok, _} = Store.add({"http://open.example/abandon", scope}, generation)
    assert :ok = Store.try_claim(scope, 10, generation)

    assert :ok = Store.abandon_inflight(scope)

    assert Store.ops_count(scope) == 1
    assert Store.inflight_count(scope) == 0
    assert Store.generation(scope) == generation + 1
    assert Store.find({"http://kept.example/abandon", scope})
    refute Store.find({"http://open.example/abandon", scope})
    assert Store.try_claim(scope, 10, generation) == :stale
  end

  defp scope(name), do: "store-#{name}-#{System.unique_integer([:positive])}"
end
