defmodule Crawler.Cookies.JarTest do
  use ExUnit.Case, async: true

  alias Crawler.Cookies
  alias Crawler.Cookies.Jar

  @url "https://example.com/account/page"

  test "header merge preserves ordered path identities and caller values" do
    jar = Cookies.store(nil, @url, ["id=root; Path=/", "id=account; Path=/account"])
    header = Cookies.header(jar, @url)

    assert Cookies.merge_header("extra=1", header) == "id=account; id=root; extra=1"

    assert Cookies.merge_header("id=caller; extra=1; extra=2", header) ==
             "id=account; id=root; extra=1; extra=2"
  end

  test "header merge preserves partitioned and unpartitioned identities" do
    context = %{site: "https://page.test/", navigation: false}
    url = "https://cdn.test/file"

    jar =
      Cookies.store(
        nil,
        url,
        [
          "id=partition; Secure; SameSite=None; Partitioned; Path=/",
          "id=global; Secure; SameSite=None; Path=/"
        ],
        context
      )

    assert Cookies.merge_header("extra=1", Cookies.header(jar, url, context)) ==
             "id=partition; id=global; extra=1"
  end

  test "response credential policy rejects storage and deletion" do
    jar = Cookies.store(nil, @url, ["id=good; Path=/"])

    for context <- [
          %{credentials: :omit},
          %{credentials: :same_origin, site: "https://foreign.test/"},
          %{credentials: :same_origin, site: "http://example.com/"},
          %{credentials: :same_origin, site: "https://example.com:8443/"},
          %{credentials: :same_site, site: "https://foreign.test/"}
        ] do
      {unchanged, outcome} =
        Cookies.store_result(jar, @url, ["id=bad; Path=/", "new=1; Path=/"], context)

      assert Cookies.header(unchanged, @url) == "id=good"
      assert outcome.processed == 0

      assert Cookies.store(jar, @url, ["id=bad; Max-Age=0; Path=/"], context) == jar
    end

    allowed = %{credentials: :same_origin, site: "https://EXAMPLE.com:443/"}
    assert Cookies.header(Cookies.store(nil, @url, ["id=1; Path=/"], allowed), @url) == "id=1"

    same_site = %{credentials: :same_site, site: "http://www.example.com:8443/"}
    assert Cookies.header(Cookies.store(nil, @url, ["id=1; Path=/"], same_site), @url) == "id=1"
  end

  test "capacity eviction is explicit and uses creation order after replacement" do
    context = %{max_cookies: 3}

    jar =
      Cookies.store(
        [],
        @url,
        ["id=root; Path=/", "id=account; Path=/account", "other=1"],
        context
      )

    jar = Cookies.store(jar, @url, ["id=updated; Path=/"], context)
    {jar, outcome} = Cookies.store_result(jar, @url, ["last=1"], context)

    assert outcome.status == :limited
    assert outcome.evicted == 1
    assert outcome.limits == [:max_cookies]
    assert Cookies.header(jar, @url) == "id=account; other=1; last=1"
    assert map_size(jar.entries) == 3
  end

  test "site capacity includes subdomains and partitions and leaves other sites intact" do
    context = %{max_cookies_per_site: 2}
    jar = Cookies.store(nil, "https://other.test/", ["other=1"], context)
    jar = Cookies.store(jar, "https://a.example.com/", ["id=one; Path=/"], context)

    jar =
      Cookies.store(
        jar,
        "https://b.example.com/",
        ["id=two; Secure; Partitioned; Path=/"],
        Map.put(context, :site, "https://page.test/")
      )

    {jar, outcome} = Cookies.store_result(jar, "https://c.example.com/", ["id=three"], context)

    assert outcome.status == :limited
    assert outcome.evicted == 1
    assert outcome.limits == [:max_cookies_per_site]
    assert Cookies.header(jar, "https://a.example.com/") == nil
    assert Cookies.header(jar, "https://other.test/") == "other=1"
    assert map_size(jar.entries) == 3
  end

  test "byte capacity evicts deterministically and oversized updates have an explicit outcome" do
    jar = Cookies.store(nil, @url, ["a=1; Path=/"])
    bytes = jar.bytes

    {jar, outcome} =
      Cookies.store_result(jar, @url, ["b=2; Path=/"], %{max_cookie_jar_bytes: bytes})

    assert outcome.status == :limited
    assert outcome.limits == [:max_cookie_jar_bytes]
    assert outcome.evicted == 1
    assert Cookies.header(jar, @url) == "b=2"
    assert jar.bytes <= bytes

    {unchanged, outcome} =
      Cookies.store_result(jar, @url, ["b=" <> String.duplicate("x", 20)], %{max_cookie_bytes: 10})

    assert unchanged.entries == jar.entries
    assert outcome.status == :limited
    assert outcome.rejected == 1
    assert outcome.processed == 1
    assert outcome.limits == [:max_cookie_bytes]
  end

  test "a response work cap stops without scanning the remainder" do
    headers = Enum.map(1..100_000, &"id#{&1}=1; Path=/")
    {jar, outcome} = Cookies.store_result(nil, @url, headers, %{max_cookie_updates: 4})

    assert outcome.status == :limited
    assert outcome.processed == 4
    assert outcome.unprocessed?
    assert outcome.limits == [:max_cookie_updates]
    assert map_size(jar.entries) == 4
    assert Cookies.header(jar, @url) == "id1=1; id2=1; id3=1; id4=1"

    {_jar, outcome} =
      Cookies.store_result(nil, @url, Enum.take(headers, 4), %{max_cookie_updates: 4})

    assert outcome.status == :ok
    refute outcome.unprocessed?
  end

  test "lowering site capacity reports and removes excess identities before new updates" do
    jar = Cookies.store(nil, @url, ["a=1; Path=/", "b=1; Path=/", "c=1; Path=/"])
    {jar, outcome} = Cookies.store_result(jar, @url, [], %{max_cookies_per_site: 1})

    assert outcome.status == :limited
    assert outcome.processed == 0
    assert outcome.evicted == 2
    assert outcome.limits == [:max_cookies_per_site]
    assert Cookies.header(jar, @url) == "c=1"
  end

  test "expired identities release capacity before a fresh update" do
    jar = Cookies.store(nil, @url, ["id=old; Path=/"], %{max_cookies: 1})
    [cookie] = Cookies.entries(jar)

    {jar, 0, _limits} =
      Jar.put(jar, %{cookie | expires_at: DateTime.add(DateTime.utc_now(), -1, :second)})

    {jar, outcome} = Cookies.store_result(jar, @url, ["new=1; Path=/"])

    assert outcome.status == :ok
    assert outcome.expired == 1
    assert outcome.evicted == 0
    assert Cookies.header(jar, @url) == "new=1"
  end

  test "all limits require finite positive integers" do
    for key <- Map.keys(Cookies.limits()), value <- [0, -1, nil, :infinity, 1.5] do
      assert_raise ArgumentError, fn -> Cookies.store_result(nil, @url, [], %{key => value}) end
    end
  end

  test "reads inspect only indexed domains even with a full unrelated jar" do
    jar =
      Enum.reduce(1..2_999, nil, fn n, jar ->
        Cookies.store(jar, "https://host#{n}.test/", ["id=1; Path=/"])
      end)

    jar = Cookies.store(jar, @url, ["local=1; Path=/"])
    assert map_size(jar.entries) == Cookies.limits().max_cookies
    assert {"local=1", ^jar, %{examined: 1, expired: 0}} = Cookies.header_result(jar, @url)
    assert {nil, ^jar, %{examined: 0}} = Cookies.header_result(jar, "https://unrelated.test/")
  end

  test "expiry releases all indexes and retained values on reads and writes" do
    empty = Jar.new(nil, %{})
    jar = Cookies.store(nil, @url, ["id=" <> String.duplicate("x", 2_000) <> "; Path=/"])
    [cookie] = Cookies.entries(jar)
    expired = Map.put(cookie, :expires_at, DateTime.add(DateTime.utc_now(), -1, :second))
    {jar, 0, _limits} = Jar.put(jar, expired)

    assert {nil, pruned, %{expired: 1, examined: 0}} = Cookies.header_result(jar, @url)
    assert pruned.entries == %{}
    assert pruned.domains == %{}
    assert pruned.sites == %{}
    assert :gb_trees.is_empty(pruned.expiry)
    assert :gb_trees.is_empty(pruned.order)
    assert pruned.bytes == 0
    assert :erts_debug.flat_size(pruned) <= :erts_debug.flat_size(empty) + 2

    {pruned, outcome} = Cookies.store_result(jar, @url, [])
    assert outcome.expired == 1
    assert pruned.entries == %{}
  end

  test "replacement removes obsolete expiry entries without retaining history" do
    jar = Cookies.store(nil, @url, ["id=1; Max-Age=60; Path=/"])

    updated =
      Enum.reduce(1..1_000, jar, fn _, jar ->
        Cookies.store(jar, @url, ["id=2; Max-Age=120; Path=/"])
      end)

    assert map_size(updated.entries) == 1
    assert :gb_trees.size(updated.expiry) == 1
    assert :gb_trees.size(updated.order) == 1
    assert :erts_debug.size(updated) <= :erts_debug.size(jar) + 2
    assert updated.next_seq == 1
  end

  test "retained cookie fields and identity indexes do not keep header backing" do
    source =
      String.duplicate("n", 80) <>
        "=" <>
        String.duplicate("v", 160) <>
        "; Path=/" <> String.duplicate("p", 90)

    backing = String.duplicate("x", 2_000_000) <> source
    header = binary_part(backing, 2_000_000, byte_size(source))
    assert :binary.referenced_byte_size(header) > 2_000_000

    jar = Cookies.store(nil, "https://example.com/", [header])
    assert_detached(jar)
    assert Jar.retained_cost(jar) < 20_000
    assert Jar.retained_cost(jar) > jar.bytes
  end

  test "the default cookie path is detached from the request URL backing" do
    host = String.duplicate("h", 80) <> ".example.com"
    source = "https://" <> host <> "/" <> String.duplicate("p", 90) <> "/file"
    backing = String.duplicate("x", 2_000_000) <> source
    url = binary_part(backing, 2_000_000, byte_size(source))
    jar = Cookies.store(nil, url, ["id=1"])
    [cookie] = Cookies.entries(jar)

    assert cookie.path == "/" <> String.duplicate("p", 90)
    assert_detached(jar)
    assert Jar.retained_cost(jar) < 20_000
  end

  test "nested binary partition fields are detached before identity insertion" do
    jar = Cookies.store(nil, @url, ["id=1; Path=/"])
    [cookie] = Cookies.entries(jar)
    backing = String.duplicate("x", 2_000_000)
    part = binary_part(backing, 10, 80)
    jar = Jar.delete(jar, cookie)
    {jar, 0, _limits} = Jar.put(jar, %{cookie | partition: %{part => [part, {part}]}})

    assert_detached(jar)
  end

  test "retained charge follows replacement, deletion, expiry and eviction" do
    empty = Jar.new(nil, %{})
    jar = Cookies.store(empty, @url, ["a=1; Path=/"], %{max_cookies: 1})
    cost = Jar.retained_cost(jar)
    assert cost > Jar.retained_cost(empty)

    replaced = Cookies.store(jar, @url, ["a=2; Path=/"])
    assert Jar.retained_cost(replaced) == cost

    {evicted, %{evicted: 1}} = Cookies.store_result(replaced, @url, ["b=1; Path=/"])
    assert Jar.retained_cost(evicted) == cost

    deleted = Cookies.store(evicted, @url, ["b=1; Path=/; Max-Age=0"])
    assert Jar.retained_cost(deleted) == Jar.retained_cost(empty)

    [cookie] = Cookies.entries(evicted)

    {expired, 0, _limits} =
      Jar.put(evicted, %{cookie | expires_at: DateTime.add(DateTime.utc_now(), -1, :second)})

    {nil, pruned, %{expired: 1}} = Cookies.header_result(expired, @url)
    assert Jar.retained_cost(pruned) == Jar.retained_cost(empty)
    assert Jar.retained_cost(nil) == 0
    assert Jar.retained_cost([]) == 0
  end

  test "empty seeds work and nonempty list storage is not accepted" do
    assert Cookies.header(nil, @url) == nil
    assert Cookies.header([], @url) == nil
    assert %Jar{} = Cookies.store([], @url, [])
    assert_raise FunctionClauseError, fn -> Cookies.store([%{}], @url, []) end
  end

  defp assert_detached(value) when is_binary(value) do
    assert :binary.referenced_byte_size(value) == byte_size(value)
  end

  defp assert_detached(value) when is_map(value) do
    Enum.each(Map.to_list(value), fn {key, value} ->
      assert_detached(key)
      assert_detached(value)
    end)
  end

  defp assert_detached(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.each(&assert_detached/1)
  end

  defp assert_detached([head | tail]) do
    assert_detached(head)
    assert_detached(tail)
  end

  defp assert_detached(_value), do: :ok
end
