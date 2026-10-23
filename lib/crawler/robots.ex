defmodule Crawler.Robots do
  @moduledoc false

  alias Crawler.Analysis.Budget
  alias Crawler.Fetcher.Requester
  alias Crawler.HTMLSpans
  alias Crawler.Robots.Directives
  alias Crawler.Site
  alias Crawler.Sitemap
  alias Crawler.Store
  alias Crawler.URL.Percent

  def allow_all, do: %{groups: [], sitemaps: []}

  def disallow_all do
    %{groups: [%{agents: ["*"], rules: [disallow: compile_rule("/")]}], sitemaps: []}
  end

  def product_token(user_agent) when is_binary(user_agent) do
    user_agent
    |> String.trim()
    |> String.split(~r/[\/\s]+/, parts: 2)
    |> hd()
  end

  def product_token(_user_agent), do: "Crawler"

  def parse(body) when is_binary(body) do
    lines =
      body
      |> strip_bom()
      |> String.split(~r/\r\n|\n|\r/)
      |> Enum.map(&strip_comment/1)
      |> Enum.map(&String.trim/1)

    %{groups: group_lines(lines), sitemaps: sitemap_lines(lines)}
  end

  def parse(_body), do: allow_all()

  def allowed?(rules, url, user_agent) do
    rules = rules || allow_all()
    groups = matching_groups(Map.get(rules, :groups, []), user_agent)
    decide(Enum.flat_map(groups, & &1.rules), url)
  end

  def permitted?(opts), do: permitted_result(opts) == {:ok, true}

  def permitted_result(opts) do
    opts = opts |> Map.new() |> Crawler.Options.assign_defaults()

    cond do
      opts[:respect_robots] == false ->
        {:ok, true}

      opts[:robots_fetch] == true ->
        {:ok, true}

      is_reference(opts[:execution_lease]) ->
        permitted_owned(opts)

      true ->
        opts = if opts[:deadline], do: Map.put(opts, :crawler_deadline, opts.deadline), else: opts
        Crawler.Store.Execution.run(opts, &permitted_owned/1)
    end
  end

  defp permitted_owned(opts) do
    case load(opts) do
      {:error, _} = error -> error
      rules -> {:ok, allowed?(rules, opts[:url], opts[:user_agent])}
    end
  end

  def parse_result(body, opts) when is_binary(body) do
    with :ok <- Crawler.Deadline.check(opts.crawler_deadline),
         true <- String.valid?(body) || {:error, :invalid_robots_encoding},
         {:ok, lines} <- count_rule_lines(body, 0, 1, opts),
         cost = 4096 + 32 * byte_size(body) + 8192 * lines,
         true <- cost <= opts.max_analysis_bytes || {:error, {:limit, :max_analysis_bytes}},
         {:ok, receipt} <- Store.reserve_resource(opts, :analysis, cost, Process.whereis(Store)),
         rules = body |> parse() |> detach_rules(),
         {:ok, bytes} <- Crawler.Store.Retained.bytes(rules, cost),
         :ok <- Store.commit_resource(receipt, bytes) do
      {:ok, rules, receipt}
    end
  end

  defp count_rule_lines(body, offset, count, opts) do
    remaining = byte_size(body) - offset

    cond do
      count > opts.max_control_entries ->
        {:error, {:limit, :max_control_entries}}

      true ->
        find_rule_line(body, offset, count, opts, remaining)
    end
  end

  defp find_rule_line(body, offset, count, opts, remaining) do
    case :binary.match(body, ["\r", "\n"], scope: {offset, remaining}) do
      :nomatch ->
        if remaining <= opts.max_control_token_bytes,
          do: {:ok, count},
          else: {:error, {:limit, :max_control_token_bytes}}

      {at, _} ->
        count_next_rule_line(body, offset, count, opts, at)
    end
  end

  defp count_next_rule_line(body, offset, count, opts, at) do
    if at - offset > opts.max_control_token_bytes do
      {:error, {:limit, :max_control_token_bytes}}
    else
      skip =
        if :binary.at(body, at) == 13 and at + 1 < byte_size(body) and
             :binary.at(body, at + 1) == 10,
           do: 2,
           else: 1

      with :ok <- Crawler.Deadline.check(opts.crawler_deadline),
           do: count_rule_lines(body, at + skip, count + 1, opts)
    end
  end

  defp detach_rules(binary) when is_binary(binary), do: :binary.copy(binary)
  defp detach_rules(list) when is_list(list), do: Enum.map(list, &detach_rules/1)

  defp detach_rules(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, detach_rules(value)} end)

  defp detach_rules(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&detach_rules/1) |> List.to_tuple()

  defp detach_rules(term), do: term

  def nofollow_result(tags, opts, %Budget{} = budget),
    do: Directives.nofollow_result(tags, opts, budget)

  def header_nofollow?(headers, user_agent) when is_list(headers) do
    case nofollow_result([], %{headers: headers, user_agent: user_agent}, Budget.unlimited()) do
      {:ok, blocked, _budget} -> blocked
      {:error, _reason} -> false
    end
  end

  def header_nofollow?(_headers, _user_agent), do: false

  def meta_nofollow?(body, user_agent) when is_binary(body) do
    body |> HTMLSpans.tags() |> meta_nofollow_tags?(user_agent)
  end

  def meta_nofollow?(_body, _user_agent), do: false

  def meta_nofollow_tags?(tags, user_agent) do
    case nofollow_result(tags, %{headers: [], user_agent: user_agent}, Budget.unlimited()) do
      {:ok, blocked, _budget} -> blocked
      {:error, _reason} -> false
    end
  end

  defp load(opts) do
    case Site.origin(opts[:url]) do
      nil -> allow_all()
      origin -> load_origin(opts, origin)
    end
  end

  defp load_origin(opts, origin) do
    case Store.claim_robots(opts[:scope], origin, opts[:generation], opts[:queue]) do
      {:ready, rules} -> rules
      :owner -> store_fetch(opts, origin)
      :retry -> load_origin(opts, origin)
      {:error, _} = error -> error
    end
  end

  defp store_fetch(opts, origin) do
    case fetch(opts, origin) do
      {:cache, rules, receipt} ->
        with :ok <-
               Store.finish_robots(
                 opts[:scope],
                 origin,
                 rules,
                 opts[:generation],
                 opts[:queue],
                 %{robots_receipt: receipt}
               ),
             :ok <- follow_site_sitemaps(opts, origin, rules) do
          rules
        end

      {:error, reason} = error ->
        result =
          case reason do
            {kind, _} when kind in [:limit, :deadline] -> error
            _ -> disallow_all()
          end

        Store.forget_robots(opts[:scope], origin, result, opts[:generation], opts[:queue])
        error

      {:temporary, rules} ->
        Store.forget_robots(opts[:scope], origin, rules, opts[:generation], opts[:queue])
        rules
    end
  end

  defp follow_site_sitemaps(opts, origin, rules) do
    if origin == Site.origin(opts[:site] || opts[:url]),
      do: Sitemap.follow(opts, origin, rules),
      else: :ok
  end

  defp fetch(opts, origin) do
    robots_opts =
      opts
      |> Map.put(:url, origin <> "/robots.txt")
      |> Map.put(:robots_fetch, true)
      |> Map.put(:cookie_navigation, false)
      |> Map.put(:respect_robots, false)
      |> Map.delete(:credentials)
      |> Map.delete(:page_open)

    with {:ok, response_receipt} <-
           Store.reserve_resource(robots_opts, :response, opts.max_body + 16_384),
         :ok <- Store.account_control_document(robots_opts),
         {:ok, prepared} <- Requester.prepare(robots_opts) do
      case Requester.send(prepared, Map.put(robots_opts, :control_accounting, true)) do
        {:ok, %{status: status, body: body} = response} ->
          with {:ok, bytes} <-
                 Crawler.Store.Retained.bytes({body, response.headers}, opts.max_body + 16_384),
               :ok <- Store.commit_resource(response_receipt, bytes) do
            cond do
              status in 200..299 and is_binary(body) -> cache_rules(body, robots_opts)
              status in 400..499 -> cache_rules("", robots_opts)
              true -> {:temporary, disallow_all()}
            end
          end

        {:error, %Crawler.HTTP.BodyTooLarge{}} ->
          {:error, {:limit, :max_body}}

        {:error, {:deadline, _}} = error ->
          error

        {:error, {:limit, _}} = error ->
          error

        _ ->
          {:temporary, disallow_all()}
      end
    end
  end

  defp cache_rules(body, opts) do
    with {:ok, rules, receipt} <- parse_result(body, opts), do: {:cache, rules, receipt}
  end

  defp matching_groups(groups, user_agent) do
    tokens = user_agent |> product_tokens() |> Enum.filter(&product_name?/1)

    agents =
      groups
      |> Enum.flat_map(& &1.agents)
      |> MapSet.new()

    case longest_token(Enum.filter(tokens, &(MapSet.member?(agents, &1) and &1 != "*"))) do
      nil -> Enum.filter(groups, &("*" in &1.agents))
      token -> Enum.filter(groups, &(token in &1.agents))
    end
  end

  defp product_name?(token), do: String.match?(token, ~r/[a-z]/)

  defp longest_token([]), do: nil

  # The same length keeps the name that appears later in the User-Agent.
  # Mozilla and Crawler are both 7 letters, and Crawler is the later one.
  defp longest_token(tokens) do
    best = tokens |> Enum.map(&String.length/1) |> Enum.max()
    tokens |> Enum.reverse() |> Enum.find(&(String.length(&1) == best))
  end

  defp decide(rules, url) do
    target = request_target(url)

    matches =
      for {kind, %{pieces: pieces, anchored?: anchored?, length: length}} <- rules,
          matches_rule?(pieces, anchored?, target) do
        {length, kind}
      end

    case matches do
      [] ->
        true

      _ ->
        best = matches |> Enum.map(&elem(&1, 0)) |> Enum.max()
        winners = for {length, kind} <- matches, length == best, do: kind
        :allow in winners
    end
  end

  defp request_target(url) do
    uri = URI.parse(to_string(url))

    path =
      case uri.path do
        path when is_binary(path) and path != "" -> compare_text(path, :path)
        _ -> "/"
      end

    case uri.query do
      nil -> path
      query -> path <> "?" <> compare_text(query, :query)
    end
  end

  defp compile_rule(pattern) do
    {body, anchored?} =
      if String.ends_with?(pattern, "$") do
        {binary_part(pattern, 0, byte_size(pattern) - 1), true}
      else
        {pattern, false}
      end

    pieces = body |> String.split("*") |> Enum.map(&canonical_piece/1)
    stars = max(length(pieces) - 1, 0)

    length =
      Enum.reduce(pieces, stars, fn piece, total -> total + byte_size(piece) end) +
        if(anchored?, do: 1, else: 0)

    %{pieces: pieces, anchored?: anchored?, length: length}
  end

  defp matches_rule?([first | rest], anchored?, target) do
    if String.starts_with?(target, first),
      do: match_pieces(rest, target, byte_size(first), anchored?),
      else: false
  end

  defp match_pieces([], target, offset, anchored?),
    do: not anchored? or offset == byte_size(target)

  defp match_pieces([last], target, offset, true) do
    byte_size(last) <= byte_size(target) - offset and String.ends_with?(target, last)
  end

  defp match_pieces(["" | rest], target, offset, anchored?),
    do: match_pieces(rest, target, offset, anchored?)

  defp match_pieces([piece | rest], target, offset, anchored?) do
    case :binary.match(target, piece, scope: {offset, byte_size(target) - offset}) do
      {at, size} -> match_pieces(rest, target, at + size, anchored?)
      :nomatch -> false
    end
  end

  defp canonical_piece(piece) do
    case String.split(piece, "?", parts: 2) do
      [path, query] -> compare_text(path, :path) <> "?" <> compare_text(query, :query)
      [path] -> compare_text(path, :path)
    end
  end

  defp compare_text(text, context) do
    text
    |> Percent.canonicalize(context)
    |> String.replace("%2a", "*")
    |> String.replace("%24", "$")
  end

  defp product_tokens(user_agent), do: Directives.product_tokens(user_agent)

  defp agent_name("*"), do: "*"

  defp agent_name(value) do
    body = String.trim_trailing(value, "*")

    cond do
      body == "" ->
        "*"

      true ->
        case Regex.run(
               ~r/[A-Za-z0-9_-]+/,
               Regex.replace(~r/[A-Za-z][A-Za-z0-9+.-]*:\/\/[^\s<>)]+/, body, " ")
             ) do
          [token] -> String.downcase(token)
          nil -> "*"
        end
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(body), do: body

  defp strip_comment(line) do
    case String.split(line, "#", parts: 2) do
      [head, _] -> head
      [head] -> head
    end
  end

  defp sitemap_lines(lines) do
    Enum.flat_map(lines, fn line ->
      case directive(line) do
        {:sitemap, url} -> [url]
        _ -> []
      end
    end)
  end

  defp group_lines(lines) do
    {groups, current} =
      Enum.reduce(lines, {[], nil}, fn
        "", acc ->
          acc

        line, {groups, nil} ->
          {groups, add_line(%{agents: [], rules: []}, line)}

        line, {groups, current} ->
          case directive(line) do
            {:agent, _agent} when current.rules != [] ->
              {push_group(groups, current), add_line(%{agents: [], rules: []}, line)}

            _ ->
              {groups, add_line(current, line)}
          end
      end)

    push_group(groups, current)
  end

  defp push_group(groups, %{agents: agents} = group) when agents != [] do
    [%{group | agents: Enum.reverse(agents), rules: Enum.reverse(group.rules)} | groups]
  end

  defp push_group(groups, _current), do: groups

  defp add_line(group, line) do
    case directive(line) do
      {:agent, agent} -> %{group | agents: [agent | group.agents]}
      {:rule, kind, path} -> %{group | rules: [{kind, compile_rule(path)} | group.rules]}
      _ -> group
    end
  end

  defp directive(line) do
    case String.split(line, ":", parts: 2) do
      [name, value] ->
        name = name |> String.trim() |> String.downcase()
        value = String.trim(value)

        cond do
          name == "user-agent" and value != "" -> {:agent, agent_name(value)}
          name == "allow" and value != "" -> {:rule, :allow, value}
          name == "disallow" and value != "" -> {:rule, :disallow, value}
          name == "sitemap" and value != "" -> {:sitemap, value}
          true -> :skip
        end

      _ ->
        :skip
    end
  end
end
