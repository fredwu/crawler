defmodule Crawler.Cookies.Jar do
  @moduledoc false

  alias Crawler.Cookies.PublicSuffix

  @metadata_bytes 4_096
  @defaults %{
    max_cookies: 3_000,
    max_cookies_per_site: 180,
    max_cookie_bytes: 4_096,
    max_cookie_jar_bytes: 1_048_576,
    max_cookie_updates: 256
  }

  defstruct entries: %{},
            domains: %{},
            sites: %{},
            order: nil,
            expiry: nil,
            next_seq: 0,
            bytes: 0,
            retained_bytes: @metadata_bytes,
            site_limits_changed?: false,
            limits: @defaults

  def defaults, do: @defaults

  # This charge includes detached binary values and conservatively budgets all
  # indexes. The serialized-cookie capacity remains a separate jar policy.
  def retained_cost(jar) when jar in [nil, []], do: 0
  def retained_cost(%__MODULE__{} = jar), do: jar.retained_bytes

  def new(jar, context) when jar in [nil, []] do
    configure(%__MODULE__{order: :gb_trees.empty(), expiry: :gb_trees.empty()}, context)
  end

  def new(%__MODULE__{} = jar, context), do: configure(jar, context)

  defp configure(jar, context) do
    limits = Map.merge(jar.limits, Map.take(context, Map.keys(@defaults)))

    Enum.each(limits, fn {name, value} ->
      unless is_integer(value) and value > 0 do
        raise ArgumentError, "#{name} must be a positive integer"
      end
    end)

    %{
      jar
      | limits: limits,
        site_limits_changed?:
          jar.site_limits_changed? or
            limits.max_cookies_per_site < jar.limits.max_cookies_per_site
    }
  end

  def identity(cookie) do
    {PublicSuffix.normalize(cookie.domain), cookie.path, cookie.name, cookie.partition}
  end

  def get(jar, cookie), do: Map.get(jar.entries, identity(cookie))
  def entries(jar), do: Enum.map(:gb_trees.values(jar.order), &Map.fetch!(jar.entries, &1))

  def prune(jar, now), do: expire(jar, DateTime.to_unix(now, :microsecond), 0)

  defp expire(jar, now, removed) do
    if :gb_trees.is_empty(jar.expiry) do
      {jar, removed}
    else
      {{deadline, _seq}, identity} = :gb_trees.smallest(jar.expiry)

      if deadline <= now do
        expire(delete(jar, identity), now, removed + 1)
      else
        {jar, removed}
      end
    end
  end

  def delete(jar, cookie) when is_map(cookie), do: delete(jar, identity(cookie))

  def delete(jar, identity) do
    case Map.pop(jar.entries, identity) do
      {nil, _entries} ->
        jar

      {cookie, entries} ->
        domain = elem(identity, 0)
        site = PublicSuffix.registrable_domain(domain)
        bucket = jar.domains |> Map.fetch!(domain) |> MapSet.delete(identity)
        site_order = :gb_trees.delete(cookie.seq, Map.fetch!(jar.sites, site))

        domains =
          if MapSet.size(bucket) == 0,
            do: Map.delete(jar.domains, domain),
            else: Map.put(jar.domains, domain, bucket)

        %{
          jar
          | entries: entries,
            domains: domains,
            sites:
              if(:gb_trees.is_empty(site_order),
                do: Map.delete(jar.sites, site),
                else: Map.put(jar.sites, site, site_order)
              ),
            order: :gb_trees.delete(cookie.seq, jar.order),
            expiry: delete_expiry(jar.expiry, cookie),
            bytes: jar.bytes - cookie_size(cookie),
            retained_bytes: jar.retained_bytes - entry_cost(cookie)
        }
    end
  end

  def put(jar, cookie) do
    cookie = detach(cookie)
    identity = identity(cookie)
    previous = Map.get(jar.entries, identity)
    seq = if previous, do: previous.seq, else: jar.next_seq
    jar = delete(jar, identity)
    cookie = Map.put(cookie, :seq, seq)
    domain = elem(identity, 0)
    site = PublicSuffix.registrable_domain(domain)

    jar = %{
      jar
      | entries: Map.put(jar.entries, identity, cookie),
        domains:
          Map.update(jar.domains, domain, MapSet.new([identity]), &MapSet.put(&1, identity)),
        sites:
          Map.update(
            jar.sites,
            site,
            :gb_trees.enter(seq, identity, :gb_trees.empty()),
            fn order ->
              :gb_trees.insert(seq, identity, order)
            end
          ),
        order: :gb_trees.insert(seq, identity, jar.order),
        expiry: insert_expiry(jar.expiry, cookie, identity),
        next_seq: max(jar.next_seq, seq + 1),
        bytes: jar.bytes + cookie_size(cookie),
        retained_bytes: jar.retained_bytes + entry_cost(cookie)
    }

    {jar, site_evicted} = enforce_site(jar, site, 0)
    {jar, evicted, limits} = enforce(jar)
    {jar, evicted + site_evicted, limited(limits, site_evicted > 0, :max_cookies_per_site)}
  end

  defp enforce_site(jar, site, removed) do
    order = Map.get(jar.sites, site, :gb_trees.empty())

    if :gb_trees.size(order) > jar.limits.max_cookies_per_site do
      {_seq, identity} = :gb_trees.smallest(order)
      enforce_site(delete(jar, identity), site, removed + 1)
    else
      {jar, removed}
    end
  end

  # Oldest creation wins eviction, including after replacement. Reads do not
  # change order, so scheduling cannot change which identity a limit removes.
  def enforce(%{site_limits_changed?: true} = jar) do
    {jar, removed} =
      Enum.reduce(Map.keys(jar.sites), {jar, 0}, fn site, {jar, removed} ->
        enforce_site(jar, site, removed)
      end)

    enforce(
      %{jar | site_limits_changed?: false},
      removed,
      limited(MapSet.new(), removed > 0, :max_cookies_per_site)
    )
  end

  def enforce(jar), do: enforce(jar, 0, MapSet.new())

  defp enforce(jar, evicted, limits) do
    limits =
      limits
      |> limited(map_size(jar.entries) > jar.limits.max_cookies, :max_cookies)
      |> limited(jar.bytes > jar.limits.max_cookie_jar_bytes, :max_cookie_jar_bytes)

    if map_size(jar.entries) > jar.limits.max_cookies or
         jar.bytes > jar.limits.max_cookie_jar_bytes do
      {_seq, identity} = :gb_trees.smallest(jar.order)
      enforce(delete(jar, identity), evicted + 1, limits)
    else
      {jar, evicted, limits}
    end
  end

  defp limited(limits, true, name), do: MapSet.put(limits, name)
  defp limited(limits, false, _name), do: limits

  def candidates(jar, host) do
    host
    |> PublicSuffix.normalize()
    |> String.split(".")
    |> domain_candidates(jar, [])
  end

  defp domain_candidates([], _jar, found), do: found

  defp domain_candidates([_label | rest] = labels, jar, found) do
    bucket = Map.get(jar.domains, Enum.join(labels, "."), MapSet.new())
    found = Enum.reduce(bucket, found, &[Map.fetch!(jar.entries, &1) | &2])
    domain_candidates(rest, jar, found)
  end

  def cookie_size(cookie), do: :erlang.external_size(Map.delete(cookie, :seq))

  defp entry_cost(cookie), do: @metadata_bytes + 8 * :erlang.external_size(cookie)

  defp detach(value) when is_binary(value), do: :binary.copy(value)

  defp detach(value) when is_map(value) do
    Map.new(Map.to_list(value), fn {key, value} -> {detach(key), detach(value)} end)
  end

  defp detach(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&detach/1) |> List.to_tuple()
  end

  defp detach([head | tail]), do: [detach(head) | detach(tail)]
  defp detach(value), do: value

  defp insert_expiry(tree, %{expires_at: nil}, _identity), do: tree

  defp insert_expiry(tree, cookie, identity) do
    :gb_trees.insert(
      {DateTime.to_unix(cookie.expires_at, :microsecond), cookie.seq},
      identity,
      tree
    )
  end

  defp delete_expiry(tree, %{expires_at: nil}), do: tree

  defp delete_expiry(tree, cookie) do
    :gb_trees.delete({DateTime.to_unix(cookie.expires_at, :microsecond), cookie.seq}, tree)
  end
end
