defmodule Crawler.Cookies do
  @moduledoc false

  alias Crawler.Cookies.PublicSuffix

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)
  @date_delimiters ~r/[\t\x20-\x2F\x3B-\x40\x5B-\x60\x7B-\x7E]+/
  @max_expires_at DateTime.new!(~D[9999-12-31], ~T[23:59:59], "Etc/UTC")

  def store(jar, request_url, headers) when is_list(headers) do
    uri = URI.parse(to_string(request_url))

    Enum.reduce(headers, jar || [], fn header, jar ->
      store_one(jar, uri, header)
    end)
  end

  def store(jar, _request_url, _headers), do: jar || []

  def header(jar, request_url) do
    uri = URI.parse(to_string(request_url))

    pairs =
      (jar || [])
      |> Enum.filter(&send?(&1, uri))
      |> Enum.map(&"#{&1.name}=#{&1.value}")

    case pairs do
      [] -> nil
      _ -> Enum.join(pairs, "; ")
    end
  end

  def merge_header(user, jar) when user in [nil, ""] and jar in [nil, ""], do: nil
  def merge_header(user, jar) when jar in [nil, ""], do: user
  def merge_header(user, jar) when user in [nil, ""], do: jar

  def merge_header(user, jar) do
    merged = Map.merge(Map.new(pairs(user)), Map.new(pairs(jar)))
    Enum.map_join(merged, "; ", fn {name, value} -> "#{name}=#{value}" end)
  end

  defp store_one(jar, %URI{host: host}, _header) when not is_binary(host), do: jar

  defp store_one(jar, %URI{} = uri, header) when is_binary(header) do
    case parse_set_cookie(header) do
      {:ok, name, value, attrs} -> accept(jar, name, value, attrs, uri)
      :error -> jar
    end
  end

  defp store_one(jar, _uri, _header), do: jar

  defp accept(jar, name, value, attrs, uri) do
    case build(name, value, attrs, uri) do
      :reject -> jar
      cookie -> keep(jar, cookie, attrs)
    end
  end

  defp keep(jar, cookie, attrs) do
    case deadline(attrs) do
      :delete -> reject(jar, cookie)
      expires_at -> replace(jar, Map.put(cookie, :expires_at, expires_at))
    end
  end

  defp build(name, value, attrs, %URI{host: host, path: uri_path}) do
    # Trailing dots are removed so replace and delete use the host send compares.
    host = host |> String.trim() |> String.trim_trailing(".") |> String.downcase()

    case domain(attrs, host) do
      :reject ->
        :reject

      {domain, host_only?} ->
        %{
          name: name,
          value: value,
          domain: domain,
          host_only?: host_only?,
          path: cookie_path(attrs, default_path(uri_path)),
          secure?: Map.has_key?(attrs, "secure")
        }
    end
  end

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

  defp send?(cookie, %URI{scheme: scheme, host: host, path: path}) when is_binary(host) do
    host = String.downcase(host)
    request_path = if is_binary(path) and path != "", do: path, else: "/"
    secure_ok? = not cookie.secure? or scheme == "https"

    host_ok? =
      if cookie.host_only?,
        do: same_host?(host, cookie.domain),
        else: domain_match?(host, cookie.domain)

    secure_ok? and host_ok? and path_match?(cookie.path, request_path) and fresh?(cookie)
  end

  defp send?(_cookie, _uri), do: false

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

  defp replace(jar, cookie), do: [cookie | reject(jar, cookie)]

  # The ASCII form is the cookie identity. The stored domain stays Unicode.
  defp reject(jar, cookie) do
    Enum.reject(jar, fn item ->
      item.name == cookie.name and item.path == cookie.path and
        same_host?(item.domain, cookie.domain)
    end)
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

  defp cookie_date(_value), do: :error

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
