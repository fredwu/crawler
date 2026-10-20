defmodule Crawler.Cookies do
  @moduledoc false

  alias Crawler.Cookies.PublicSuffix

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)
  @date_delimiters ~r/[\t\x20-\x2F\x3B-\x40\x5B-\x60\x7B-\x7E]+/
  @max_expires_at DateTime.new!(~D[9999-12-31], ~T[23:59:59], "Etc/UTC")

  def store(jar, request_url, headers, context \\ %{})

  def store(jar, request_url, headers, context) when is_list(headers) do
    uri = URI.parse(to_string(request_url))
    context = normalize_context(context)

    Enum.reduce(headers, jar || [], fn header, jar ->
      store_one(jar, uri, header, context)
    end)
  end

  def store(jar, _request_url, _headers, _context), do: jar || []

  def header(jar, request_url, context \\ %{}) do
    uri = URI.parse(to_string(request_url))
    context = normalize_context(context)
    document = document_uri(uri, context)
    mode = credential_mode(context)
    navigation = navigating?(context, mode)

    pairs =
      (jar || [])
      |> Enum.filter(&send?(&1, uri, document, navigation, mode))
      |> Enum.sort_by(&{-String.length(&1.path), Map.get(&1, :seq, 0)})
      |> Enum.map(&"#{&1.name}=#{&1.value}")

    case pairs do
      [] -> nil
      _ -> Enum.join(pairs, "; ")
    end
  end

  # A page open follows a link or a document redirect. Robots and sitemap
  # fetches inherit the document tags, so those flags are not page opens.
  # Prefetch sets `:page_open` to false and keeps the link tags.
  def request_navigation?(opts) when is_map(opts) do
    opts[:robots_fetch] != true and opts[:sitemap_fetch] != true and
      opts[:cookie_navigation] != false and opts[:page_open] != false and
      opts[:html_tag] == "a" and opts[:reference_tag] in [nil, "a", "area", "meta"]
  end

  def request_navigation?(_opts), do: false

  def assign_landed_site(opts, url) when is_map(opts) do
    if request_navigation?(opts), do: Map.put(opts, :cookie_site, url), else: opts
  end

  def credential_mode(context) do
    case normalize_context(context) do
      %{credentials: mode} when mode in [:include, :same_origin, :same_site] -> mode
      _context -> :include
    end
  end

  # Scheme, host, and port. Default ports match an omitted port. The host
  # comparison is case-insensitive. Same-site still ignores scheme and port.
  def same_origin?(left, right) do
    case {origin(left), origin(right)} do
      {origin, origin} when origin != :error -> true
      _other -> false
    end
  end

  # The caller cookie follows the credential mode. The host rule stays outside.
  def caller_cookie?(url, context) do
    context = normalize_context(context)
    caller_cookie?(URI.parse(to_string(url)), context, credential_mode(context))
  end

  def merge_header(user, jar) when user in [nil, ""] and jar in [nil, ""], do: nil
  def merge_header(user, jar) when jar in [nil, ""], do: user
  def merge_header(user, jar) when user in [nil, ""], do: jar

  def merge_header(user, jar) do
    merged = Map.merge(Map.new(pairs(user)), Map.new(pairs(jar)))
    Enum.map_join(merged, "; ", fn {name, value} -> "#{name}=#{value}" end)
  end

  defp store_one(jar, %URI{host: host}, _header, _context) when not is_binary(host), do: jar

  defp store_one(jar, %URI{} = uri, header, context) when is_binary(header) do
    case parse_set_cookie(header) do
      {:ok, name, value, attrs} -> accept(jar, name, value, attrs, uri, context)
      :error -> jar
    end
  end

  defp store_one(jar, _uri, _header, _context), do: jar

  defp accept(jar, name, value, attrs, uri, context) do
    case build(name, value, attrs, uri, context) do
      :reject -> jar
      cookie -> if allow_store?(jar, cookie, uri), do: keep(jar, cookie, attrs), else: jar
    end
  end

  defp keep(jar, cookie, attrs) do
    case deadline(attrs) do
      :delete -> reject(jar, cookie)
      expires_at -> replace(jar, Map.put(cookie, :expires_at, expires_at))
    end
  end

  defp build(name, value, attrs, %URI{scheme: scheme, host: host, path: uri_path} = uri, context) do
    # Trailing dots are removed so replace and delete use the host send compares.
    host = host |> String.trim() |> String.trim_trailing(".") |> String.downcase()

    case domain(attrs, host) do
      :reject ->
        :reject

      {domain, host_only?} ->
        shaped(name, value, attrs, uri, context, scheme, domain, host_only?, uri_path)
    end
  end

  defp shaped(name, value, attrs, uri, context, scheme, domain, host_only?, uri_path) do
    cookie = %{
      name: name,
      value: value,
      domain: domain,
      host_only?: host_only?,
      path: cookie_path(attrs, default_path(uri_path)),
      secure?: Map.has_key?(attrs, "secure"),
      same_site: same_site(attrs),
      partition: partition(attrs, uri, context)
    }

    if stored_shape?(cookie, scheme), do: cookie, else: :reject
  end

  # SameSite=None is kept only with Secure. Http still cannot plant it.
  defp stored_shape?(%{same_site: :none, secure?: false}, _scheme), do: false
  defp stored_shape?(cookie, scheme), do: prefix_ok?(cookie, scheme)

  # `__Host-` and `__Secure-` are case-sensitive. An http response cannot plant
  # or replace a Secure cookie; https can.
  defp allow_store?(_jar, %{secure?: true}, %URI{scheme: scheme}) when scheme != "https",
    do: false

  defp allow_store?(jar, %{secure?: false} = cookie, %URI{scheme: scheme})
       when scheme != "https" do
    not secure_identity?(jar, cookie)
  end

  defp allow_store?(_jar, _cookie, _uri), do: true

  defp secure_identity?(jar, cookie) do
    Enum.any?(jar, fn item -> item.secure? and same_cookie?(item, cookie) end)
  end

  defp prefix_ok?(%{name: "__Host-" <> _} = cookie, scheme) do
    cookie.secure? and cookie.host_only? and cookie.path == "/" and scheme == "https"
  end

  defp prefix_ok?(%{name: "__Secure-" <> _, secure?: secure?}, _scheme), do: secure?

  defp prefix_ok?(_cookie, _scheme), do: true

  defp cookie_path(attrs, default) do
    case Map.get(attrs, "path") do
      path when is_binary(path) ->
        if String.starts_with?(path, "/"), do: path, else: default

      _ ->
        default
    end
  end

  defp domain(attrs, host) do
    case Map.get(attrs, "domain") do
      nil ->
        {host, true}

      domain when is_binary(domain) ->
        stored = stored_domain(domain)
        # Trailing dots and IDNA are folded before the address check.
        ascii = PublicSuffix.normalize(stored)
        host = PublicSuffix.normalize(host)

        cond do
          stored == "" or ascii == "" -> :reject
          not String.valid?(ascii) -> :reject
          # An empty label is not a registrable name. co..uk must not bypass co.uk.
          String.contains?(ascii, "..") -> :reject
          ip?(host) or ip?(ascii) -> :reject
          not domain_match?(host, stored) -> :reject
          PublicSuffix.public_suffix?(stored) -> :reject
          true -> {stored, false}
        end

      _ ->
        :reject
    end
  end

  defp deadline(attrs) do
    case Map.get(attrs, "max-age") do
      nil ->
        expires_at(Map.get(attrs, "expires"))

      value ->
        case Integer.parse(to_string(value)) do
          {age, ""} when age <= 0 -> :delete
          {age, ""} -> capped_deadline(age)
          _ -> expires_at(Map.get(attrs, "expires"))
        end
    end
  end

  # DateTime.add/3 walks each year, so a huge Max-Age is capped before adding.
  defp capped_deadline(age) do
    now = DateTime.utc_now()
    room = DateTime.diff(@max_expires_at, now, :second)

    if age < room, do: DateTime.add(now, age, :second), else: @max_expires_at
  end

  defp expires_at(value) when is_binary(value) do
    case cookie_date(value) do
      {:ok, datetime} ->
        if DateTime.compare(datetime, DateTime.utc_now()) == :gt, do: datetime, else: :delete

      :error ->
        nil
    end
  end

  defp expires_at(_value), do: nil

  defp navigating?(context, mode) do
    context[:navigation] != false and mode != :same_site
  end

  defp caller_cookie?(_request, _context, :include), do: true

  defp caller_cookie?(request, context, mode) do
    credential_ok?(request, document_uri(request, context), mode)
  end

  defp send?(cookie, uri, document, navigation, mode) do
    credential_ok?(uri, document, mode) and request_ok?(cookie, uri, document, navigation)
  end

  defp credential_ok?(%URI{host: host}, %URI{host: document_host}, :same_site)
       when is_binary(host) and is_binary(document_host) do
    same_registrable_site?(host, document_host)
  end

  defp credential_ok?(%URI{} = request, %URI{} = document, :same_origin) do
    same_origin?(request, document)
  end

  defp credential_ok?(_request, _document, :include), do: true
  defp credential_ok?(_request, _document, _mode), do: false

  defp request_ok?(cookie, %URI{scheme: scheme, host: host, path: path}, document, navigation)
       when is_binary(host) do
    host = String.downcase(host)
    request_path = if is_binary(path) and path != "", do: path, else: "/"
    secure_ok? = not cookie.secure? or scheme == "https"

    host_ok? =
      if cookie.host_only?,
        do: same_host?(host, cookie.domain),
        else: domain_match?(host, cookie.domain)

    secure_ok? and host_ok? and path_match?(cookie.path, request_path) and fresh?(cookie) and
      site_ok?(cookie, host, document.host, navigation) and partition_ok?(cookie, document.host)
  end

  defp request_ok?(_cookie, _uri, _document, _navigation), do: false

  defp origin(%URI{scheme: scheme, host: host} = uri)
       when is_binary(scheme) and is_binary(host) and host != "" do
    {String.downcase(scheme), String.downcase(host), origin_port(uri)}
  end

  defp origin(%URI{}), do: :error
  defp origin(url) when is_binary(url), do: url |> URI.parse() |> origin()
  defp origin(_value), do: :error

  defp origin_port(%URI{scheme: scheme, port: port}) do
    scheme = scheme_name(scheme)

    cond do
      is_integer(port) -> port
      scheme == "https" -> 443
      scheme == "http" -> 80
      true -> nil
    end
  end

  defp scheme_name(scheme) when is_binary(scheme), do: String.downcase(scheme)
  defp scheme_name(_scheme), do: nil

  defp site_ok?(cookie, request_host, document_host, navigation) do
    same = same_registrable_site?(request_host, document_host)

    case Map.get(cookie, :same_site, :lax) do
      :none -> true
      :strict -> same
      _ -> same or navigation
    end
  end

  defp same_registrable_site?(left, right) do
    site = PublicSuffix.registrable_domain(left)
    site != "" and site == PublicSuffix.registrable_domain(right)
  end

  defp partition_ok?(cookie, document_host) do
    case Map.get(cookie, :partition) do
      nil -> true
      partition -> partition == PublicSuffix.registrable_domain(document_host)
    end
  end

  defp fresh?(cookie) do
    case Map.get(cookie, :expires_at) do
      nil -> true
      expires_at -> DateTime.compare(expires_at, DateTime.utc_now()) == :gt
    end
  end

  defp path_match?(cookie_path, request_path) do
    cond do
      cookie_path == "/" ->
        true

      request_path == cookie_path ->
        true

      String.ends_with?(cookie_path, "/") and String.starts_with?(request_path, cookie_path) ->
        true

      String.starts_with?(request_path, cookie_path <> "/") ->
        true

      true ->
        false
    end
  end

  defp stored_domain(domain) do
    domain
    |> String.trim()
    |> String.trim_leading(".")
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp same_host?(host, domain) do
    PublicSuffix.normalize(host) == PublicSuffix.normalize(domain)
  end

  # The jar keeps the Unicode domain. Matching uses the ASCII form.
  defp domain_match?(host, domain) do
    host = PublicSuffix.normalize(host)
    domain = PublicSuffix.normalize(domain)
    host != "" and (host == domain or String.ends_with?(host, "." <> domain))
  end

  # :seq is the creation order. A replace keeps that place, so the list order is not the send order.
  defp replace(jar, cookie) do
    case Enum.find(jar, &same_cookie?(&1, cookie)) do
      nil -> jar ++ [Map.put(cookie, :seq, next_seq(jar))]
      current -> rewrite(jar, cookie, Map.get(current, :seq, next_seq(jar)))
    end
  end

  defp rewrite(jar, cookie, seq) do
    Enum.map(jar, &rewrite_one(&1, cookie, seq))
  end

  defp rewrite_one(item, cookie, seq) do
    if same_cookie?(item, cookie), do: Map.put(cookie, :seq, seq), else: item
  end

  defp next_seq([]), do: 0

  defp next_seq(jar) do
    jar |> Enum.map(&Map.get(&1, :seq, 0)) |> Enum.max() |> then(&(&1 + 1))
  end

  # The ASCII form is the cookie identity. The stored domain stays Unicode.
  defp reject(jar, cookie), do: Enum.reject(jar, &same_cookie?(&1, cookie))

  defp same_cookie?(item, cookie) do
    item.name == cookie.name and item.path == cookie.path and
      same_host?(item.domain, cookie.domain) and
      Map.get(item, :partition) == Map.get(cookie, :partition)
  end

  defp parse_set_cookie(header) do
    case String.split(header, ";") do
      [pair | attrs] -> parse_pair(pair, attrs)
      _ -> :error
    end
  end

  defp parse_pair(pair, attrs) do
    case String.split(pair, "=", parts: 2) do
      [name, value] -> named_cookie(String.trim(name), value, attrs)
      _ -> :error
    end
  end

  defp named_cookie("", _value, _attrs), do: :error

  defp named_cookie(name, value, attrs) do
    {:ok, name, String.trim(value), attributes(attrs)}
  end

  defp attributes(segments) do
    Map.new(segments, fn segment ->
      case String.split(String.trim(segment), "=", parts: 2) do
        [name, value] -> {name |> String.trim() |> String.downcase(), String.trim(value)}
        [name] -> {name |> String.trim() |> String.downcase(), true}
      end
    end)
  end

  defp pairs(header) do
    header
    |> String.split(";")
    |> Enum.flat_map(fn piece ->
      case String.split(String.trim(piece), "=", parts: 2) do
        [name, value] when name != "" -> [{name, value}]
        _ -> []
      end
    end)
  end

  defp ip?(host) do
    String.valid?(host) and
      match?({:ok, _address}, :inet.parse_address(String.to_charlist(host)))
  end

  defp cookie_date(value) when is_binary(value) do
    found =
      value
      |> date_tokens()
      |> Enum.reduce(%{time: nil, day: nil, month: nil, year: nil}, &take_date_token/2)

    # The first year token is kept. A value below 1601 aborts the whole date.
    with {hour, minute, second} <- found.time,
         true <- hour in 0..23 and minute in 0..59 and second in 0..59,
         day when day in 1..31 <- found.day,
         month when is_integer(month) <- found.month,
         year when is_integer(year) and year >= 1601 <- found.year,
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second),
         {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
      {:ok, datetime}
    else
      _ -> :error
    end
  end

  defp date_tokens(value), do: String.split(value, @date_delimiters, trim: true)

  defp take_date_token(token, found) do
    cond do
      is_nil(found.time) and match?({:ok, _}, time_token(token)) ->
        {:ok, time} = time_token(token)
        %{found | time: time}

      is_nil(found.day) and match?({:ok, _}, day_token(token)) ->
        {:ok, day} = day_token(token)
        %{found | day: day}

      is_nil(found.month) and match?({:ok, _}, month_token(token)) ->
        {:ok, month} = month_token(token)
        %{found | month: month}

      is_nil(found.year) and match?({:ok, _}, year_token(token)) ->
        {:ok, year} = year_token(token)
        %{found | year: year}

      true ->
        found
    end
  end

  defp time_token(token) do
    case Regex.run(~r/^(\d{1,2}):(\d{1,2}):(\d{1,2})(?:\D.*)?$/, token) do
      [_, hour, minute, second] ->
        {:ok, {String.to_integer(hour), String.to_integer(minute), String.to_integer(second)}}

      _ ->
        :error
    end
  end

  defp day_token(token) do
    case Regex.run(~r/^(\d{1,2})(?:\D.*)?$/, token) do
      [_, digits] -> {:ok, String.to_integer(digits)}
      _ -> :error
    end
  end

  defp month_token(token) do
    lower = String.downcase(token)

    Enum.find_value(Enum.with_index(@months, 1), fn {name, number} ->
      if String.starts_with?(lower, name), do: {:ok, number}
    end) || :error
  end

  defp year_token(token) do
    case Regex.run(~r/^(\d{2,4})(?:\D.*)?$/, token) do
      [_, digits] -> normalize_year(String.to_integer(digits))
      _ -> :error
    end
  end

  defp normalize_year(year) when year <= 69, do: {:ok, year + 2000}
  defp normalize_year(year) when year <= 99, do: {:ok, year + 1900}
  defp normalize_year(year), do: {:ok, year}

  defp same_site(attrs) do
    case attrs |> Map.get("samesite") |> same_site_token() do
      "none" -> :none
      "strict" -> :strict
      _ -> :lax
    end
  end

  defp same_site_token(value) when is_binary(value) do
    value |> String.trim() |> String.downcase()
  end

  defp same_site_token(_value), do: ""

  defp partition(attrs, request_uri, context) do
    if Map.has_key?(attrs, "partitioned") do
      %URI{host: host} = document_uri(request_uri, context)
      PublicSuffix.registrable_domain(host)
    else
      nil
    end
  end

  defp document_uri(%URI{} = request_uri, context) do
    case context_site(context) do
      nil -> request_uri
      site -> URI.parse(site)
    end
  end

  defp context_site(%{site: site}) when is_binary(site) and site != "", do: site
  defp context_site(_context), do: nil

  defp normalize_context(context) when is_map(context), do: context
  defp normalize_context(context) when is_list(context), do: Map.new(context)
  defp normalize_context(_context), do: %{}

  defp default_path(path) when not is_binary(path) or path == "", do: "/"

  defp default_path(path) do
    cond do
      not String.starts_with?(path, "/") ->
        "/"

      true ->
        case :binary.matches(path, "/") do
          matches when length(matches) < 2 ->
            "/"

          matches ->
            {start, _length} = List.last(matches)
            binary_part(path, 0, start)
        end
    end
  end
end
