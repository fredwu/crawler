defmodule Crawler.Robots do
  @moduledoc false

  alias Crawler.Fetcher.Requester
  alias Crawler.HTMLSpans
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

  def permitted?(opts) do
    cond do
      opts[:respect_robots] == false -> true
      opts[:robots_fetch] == true -> true
      true -> allowed?(load(opts), opts[:url], opts[:user_agent])
    end
  end

  def header_nofollow?(headers, user_agent) when is_list(headers) do
    tokens = token_set(user_agent)

    Enum.any?(headers, fn {name, value} ->
      String.downcase(to_string(name)) == "x-robots-tag" and directives_block?(value, tokens)
    end)
  end

  def header_nofollow?(_headers, _user_agent), do: false

  def meta_nofollow?(body, user_agent) when is_binary(body) do
    tokens = token_set(user_agent)

    body
    |> HTMLSpans.tags()
    |> Enum.any?(fn tag ->
      tag.name == "meta" and not tag.closing? and not tag.in_template? and
        meta_blocks?(tag, tokens)
    end)
  end

  def meta_nofollow?(_body, _user_agent), do: false

  defp load(opts) do
    case Site.origin(opts[:url]) do
      nil -> allow_all()
      origin -> load_origin(opts, origin)
    end
  end

  defp load_origin(opts, origin) do
    case Store.claim_robots(opts[:scope], origin) do
      {:ready, rules} -> rules
      :owner -> store_fetch(opts, origin)
    end
  end

  defp store_fetch(opts, origin) do
    case fetch(opts, origin) do
      {:cache, rules} ->
        Store.finish_robots(opts[:scope], origin, rules)
        Sitemap.follow(opts, origin, rules)
        rules

      {:temporary, rules} ->
        Store.forget_robots(opts[:scope], origin, rules)
        rules
    end
  end

  defp fetch(opts, origin) do
    robots_opts =
      opts
      |> Map.put(:url, origin <> "/robots.txt")
      |> Map.put(:robots_fetch, true)
      |> Map.put(:respect_robots, false)

    case Requester.make(robots_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        if String.valid?(body), do: {:cache, parse(body)}, else: {:temporary, disallow_all()}

      {:ok, %{status: status}} when status in 400..499 ->
        {:cache, allow_all()}

      _ ->
        {:temporary, disallow_all()}
    end
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
      for {kind, %{regex: regex, length: length}} <- rules,
          Regex.match?(regex, target) do
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
    source = "\\A" <> Enum.map_join(pieces, ".*", &Regex.escape/1)
    source = if anchored?, do: source <> "\\z", else: source
    stars = max(length(pieces) - 1, 0)

    length =
      Enum.reduce(pieces, stars, fn piece, total -> total + byte_size(piece) end) +
        if(anchored?, do: 1, else: 0)

    %{regex: Regex.compile!(source), length: length}
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

  defp product_tokens(nil), do: ["crawler"]

  defp product_tokens(user_agent) when is_binary(user_agent) do
    ~r/[A-Za-z0-9_-]+/
    |> Regex.scan(user_agent)
    |> Enum.map(fn [token] -> String.downcase(token) end)
  end

  defp product_tokens(_user_agent), do: ["crawler"]

  defp token_set(user_agent), do: MapSet.new(product_tokens(user_agent))

  defp agent_name("*"), do: "*"

  defp agent_name(value) do
    body = String.trim_trailing(value, "*")

    cond do
      body == "" ->
        "*"

      true ->
        case product_tokens(body) do
          [token | _] -> token
          [] -> "*"
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

  defp meta_blocks?(tag, tokens) do
    name = tag |> HTMLSpans.value("name") |> to_string() |> String.trim() |> String.downcase()
    content = HTMLSpans.value(tag, "content") || ""
    (name == "robots" or MapSet.member?(tokens, name)) and directives_block?(content, tokens)
  end

  defp directives_block?(value, tokens) when is_binary(value) do
    value
    |> String.downcase()
    |> String.split(",")
    |> Enum.any?(fn piece ->
      piece = String.trim(piece)

      case String.split(piece, ":", parts: 2) do
        [directive] ->
          directive in ["nofollow", "none"]

        [agent, directive] ->
          MapSet.member?(tokens, String.trim(agent)) and
            String.trim(directive) in ["nofollow", "none"]
      end
    end)
  end

  defp directives_block?(_value, _tokens), do: false
end
