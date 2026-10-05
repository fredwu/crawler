defmodule Crawler.Robots do
  @moduledoc false

  alias Crawler.Fetcher.Requester
  alias Crawler.HTMLSpans
  alias Crawler.Site
  alias Crawler.Store

  def allow_all, do: %{groups: []}

  def disallow_all, do: %{groups: [%{agents: ["*"], rules: [disallow: "/"]}]}

  def product_token(user_agent) when is_binary(user_agent) do
    user_agent
    |> String.trim()
    |> String.split(~r/[\/\s]+/, parts: 2)
    |> hd()
  end

  def product_token(_user_agent), do: "Crawler"

  def parse(body) when is_binary(body) do
    groups =
      body
      |> String.split(~r/\r\n|\n|\r/)
      |> Enum.map(&strip_comment/1)
      |> Enum.map(&String.trim/1)
      |> group_lines()

    %{groups: groups}
  end

  def parse(_body), do: allow_all()

  def allowed?(rules, url, user_agent) do
    rules = rules || allow_all()
    token = product_token(user_agent) |> String.downcase()
    groups = matching_groups(rules.groups, token)
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
    token = product_token(user_agent) |> String.downcase()

    Enum.any?(headers, fn {name, value} ->
      String.downcase(to_string(name)) == "x-robots-tag" and directives_block?(value, token)
    end)
  end

  def header_nofollow?(_headers, _user_agent), do: false

  def meta_nofollow?(body, user_agent) when is_binary(body) do
    token = product_token(user_agent) |> String.downcase()

    body
    |> HTMLSpans.tags()
    |> Enum.any?(fn tag ->
      tag.name == "meta" and not tag.closing? and not tag.in_template? and
        meta_blocks?(tag, token)
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
        {:cache, parse(body)}

      {:ok, %{status: status}} when status in 400..499 ->
        {:cache, allow_all()}

      _ ->
        {:temporary, disallow_all()}
    end
  end

  defp matching_groups(groups, token) do
    specific = Enum.filter(groups, &(token in &1.agents))
    if specific == [], do: Enum.filter(groups, &("*" in &1.agents)), else: specific
  end

  defp decide(rules, url) do
    matches =
      for {kind, pattern} <- rules,
          pattern != "",
          rule_match?(pattern, target(url, pattern)) do
        {byte_size(pattern), kind}
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

  defp target(url, pattern) do
    uri = URI.parse(url)
    path = if is_binary(uri.path) and uri.path != "", do: uri.path, else: "/"

    if String.contains?(pattern, "?") do
      path <> "?" <> (uri.query || "")
    else
      path
    end
  end

  defp rule_match?(pattern, path) do
    anchored = String.ends_with?(pattern, "$")
    body = if anchored, do: String.trim_trailing(pattern, "$"), else: pattern

    source =
      body
      |> String.split("*", trim: false)
      |> Enum.map_join(".*", &Regex.escape/1)

    source = if anchored, do: "\\A" <> source <> "\\z", else: "\\A" <> source
    Regex.match?(Regex.compile!(source), path)
  end

  defp strip_comment(line) do
    case String.split(line, "#", parts: 2) do
      [head, _] -> head
      [head] -> head
    end
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
      {:rule, kind, path} -> %{group | rules: [{kind, path} | group.rules]}
      :skip -> group
    end
  end

  defp directive(line) do
    case String.split(line, ":", parts: 2) do
      [name, value] ->
        name = name |> String.trim() |> String.downcase()
        value = String.trim(value)

        cond do
          name == "user-agent" and value != "" -> {:agent, String.downcase(value)}
          name == "allow" -> {:rule, :allow, value}
          name == "disallow" -> {:rule, :disallow, value}
          true -> :skip
        end

      _ ->
        :skip
    end
  end

  defp meta_blocks?(tag, token) do
    name = tag |> HTMLSpans.value("name") |> to_string() |> String.trim() |> String.downcase()
    content = HTMLSpans.value(tag, "content") || ""
    name in ["robots", token] and directives_block?(content, token)
  end

  defp directives_block?(value, token) when is_binary(value) do
    value
    |> String.downcase()
    |> String.split(",")
    |> Enum.any?(fn piece ->
      piece = String.trim(piece)

      case String.split(piece, ":", parts: 2) do
        [directive] ->
          directive in ["nofollow", "none"]

        [agent, directive] ->
          String.trim(agent) == token and String.trim(directive) in ["nofollow", "none"]
      end
    end)
  end

  defp directives_block?(_value, _token), do: false
end
