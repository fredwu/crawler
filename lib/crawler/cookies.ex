defmodule Crawler.Cookies do
  @moduledoc false

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)

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
    if delete?(attrs), do: reject(jar, cookie), else: replace(jar, cookie)
  end

  defp build(name, value, attrs, %URI{host: host, path: uri_path}) do
    host = String.downcase(host)

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
        domain = domain |> String.trim() |> String.trim_leading(".") |> String.downcase()

        cond do
          domain == "" -> :reject
          ip?(host) -> :reject
          domain_match?(host, domain) -> {domain, false}
          true -> :reject
        end

      _ ->
        :reject
    end
  end

  defp delete?(attrs) do
    case Map.get(attrs, "max-age") do
      nil ->
        expired?(Map.get(attrs, "expires"))

      value ->
        case Integer.parse(to_string(value)) do
          {age, ""} -> age <= 0
          _ -> expired?(Map.get(attrs, "expires"))
        end
    end
  end

  defp expired?(value) when is_binary(value) do
    case http_date(value) do
      {:ok, datetime} -> DateTime.compare(datetime, DateTime.utc_now()) != :gt
      :error -> false
    end
  end

  defp expired?(_value), do: false

  defp send?(cookie, %URI{scheme: scheme, host: host, path: path}) when is_binary(host) do
    host = String.downcase(host)
    request_path = if is_binary(path) and path != "", do: path, else: "/"
    secure_ok? = not cookie.secure? or scheme == "https"

    host_ok? =
      if cookie.host_only?, do: host == cookie.domain, else: domain_match?(host, cookie.domain)

    secure_ok? and host_ok? and path_match?(cookie.path, request_path)
  end

  defp send?(_cookie, _uri), do: false

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

  defp domain_match?(host, domain) do
    host == domain or String.ends_with?(host, "." <> domain)
  end

  defp replace(jar, cookie), do: [cookie | reject(jar, cookie)]

  defp reject(jar, cookie) do
    Enum.reject(jar, fn item ->
      item.name == cookie.name and item.domain == cookie.domain and item.path == cookie.path
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
    match?({:ok, _address}, :inet.parse_address(String.to_charlist(host)))
  end

  defp http_date(value) do
    case Regex.run(
           ~r/^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/,
           String.trim(value)
         ) do
      [_, day, month, year, hour, minute, second] ->
        with month when is_integer(month) <- month_number(month),
             {:ok, date} <- Date.new(int(year), month, int(day)),
             {:ok, time} <- Time.new(int(hour), int(minute), int(second)),
             {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
          {:ok, datetime}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp month_number(month) do
    case Enum.find_index(@months, &(&1 == String.downcase(month))) do
      nil -> :error
      index -> index + 1
    end
  end

  defp int(value), do: String.to_integer(value)

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
