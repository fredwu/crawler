defmodule Crawler.StoreScopeIdentityTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  for event <- [:stop, :force] do
    test "#{event} uses a tuple scope as an exact value and preserves the Store", context do
      exercise_tuple_scope(unquote(event), context)
    end
  end

  test "dropping an integer scope preserves a numerically equal float scope", %{url: url} do
    integer = System.unique_integer([:positive])
    float = integer * 1.0
    integer_key = {url <> "/numeric-scope", integer}
    float_key = {url <> "/numeric-scope", float}
    on_exit(fn -> Store.drop_scope(integer) end)
    on_exit(fn -> Store.drop_scope(float) end)
    store = Process.whereis(Store)

    assert {:ok, _} = Store.add(integer_key)
    assert {:ok, _} = Store.add(float_key)
    assert {_, _} = Store.add_page_data(integer_key, "INTEGER", %{})
    assert {_, _} = Store.add_page_data(float_key, "FLOAT", %{})
    assert :ok = Store.ops_inc(integer)
    assert :ok = Store.ops_inc(float)
    assert :ok = Store.note_enqueued(float, 0, nil)
    assert {:ok, float_claim} = Store.start_work(%{scope: float, generation: 0, max_pages: 2})

    assert Store.drop_scope(integer) == 1
    refute Store.find(integer_key)
    assert Store.find(float_key).body == "FLOAT"
    assert Store.ops_count(integer) == 0
    assert Store.ops_count(float) == 1
    assert Store.generation(integer) == 1
    assert Store.generation(float) == 0
    assert Process.whereis(Store) == store
    assert Store.pending_count(float) == 1
    assert Store.inflight_count(float) == 1
    assert :ok = Store.finish_claim(float_claim)
    assert Store.pending_count(float) == 0
    assert Store.inflight_count(float) == 0
    assert Store.find(float_key).body == "FLOAT"

    assert Store.drop_scope(float) == 1
    refute Store.find(float_key)
    assert Process.whereis(Store) == store
  end

  defp exercise_tuple_scope(event, %{site: site, url: url, req_options: req_options}) do
    scope = {:tenant, System.unique_integer([:positive])}
    unrelated = {:tenant, System.unique_integer([:positive])}
    key = {url <> "/tuple-scope", scope}
    unrelated_key = {url <> "/tuple-scope", unrelated}
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    store = Process.whereis(Store)
    on_exit(fn -> Store.drop_scope(unrelated) end)

    ReqTestSite.expect(site, "GET", "/tuple-scope", fn conn ->
      count = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
      Plug.Conn.resp(conn, 200, "version #{count}")
    end)

    assert {:ok, _} = Store.add(unrelated_key)
    assert {_, _} = Store.add_page_data(unrelated_key, "UNRELATED", %{})
    assert :ok = Store.ops_inc(unrelated)
    unrelated_page = Store.find(unrelated_key)

    assert {:ok, opts} =
             Crawler.crawl(elem(key, 0),
               scope: scope,
               workers: 1,
               max_pages: 1,
               retries: 0,
               store: Store,
               req_options: req_options
             )

    on_exit(fn -> Crawler.stop(opts) end)
    await_idle(opts)
    assert Store.find_processed(key).body == "version 1"
    assert Store.ops_count(scope) == 1
    exercise_action(event, opts, key, attempts)
    assert Process.whereis(Store) == store
    assert Process.alive?(store)
    assert Store.find(unrelated_key) == unrelated_page
    assert Store.ops_count(unrelated) == 1
    assert Store.generation(unrelated) == 0
  end

  defp exercise_action(:stop, opts, key, attempts) do
    assert :ok = Crawler.stop(opts)
    refute Process.alive?(opts[:queue])
    refute Store.find(key)
    assert Store.ops_count(opts[:scope]) == 0
    assert Store.pending_count(opts[:scope]) == 0
    assert Store.inflight_count(opts[:scope]) == 0
    assert Agent.get(attempts, & &1) == 1
  end

  defp exercise_action(:force, opts, key, attempts) do
    assert {:ok, forced} = Crawler.crawl(elem(key, 0), Map.put(opts, :force, true))
    await_idle(forced)
    assert forced[:queue] == opts[:queue]
    assert forced[:generation] == opts[:generation] + 1
    assert Store.find_processed(key).body == "version 2"
    assert Store.ops_count(opts[:scope]) == 1
    assert Store.pending_count(opts[:scope]) == 0
    assert Store.inflight_count(opts[:scope]) == 0
    assert Agent.get(attempts, & &1) == 2
  end
end
