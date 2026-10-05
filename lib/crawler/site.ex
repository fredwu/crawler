defmodule Crawler.Site do
  @moduledoc false

  @doc """
  Whether two URLs belong to the same crawl site.

  The host is compared without one leading `www` label. `http` on port 80 and
  `https` on port 443 match each other. Every other pair must use the same port.
  """
  def same_site?(seed, url) when is_binary(seed) and is_binary(url) do
    case {identity(seed), identity(url)} do
      {{host, port, _left}, {host, port, _right}} ->
        true

      {{host, left_port, left_scheme}, {host, right_port, right_scheme}} ->
        default_pair?(left_scheme, left_port, right_scheme, right_port)

      _ ->
        false
    end
  end

  def same_site?(_seed, _url), do: false

  @doc """
  Origin used for `robots.txt`.

  The host is not rewritten, so `www` keeps its own file. Default ports are omitted.
  """
  def origin(url) when is_binary(url) do
    case uri(url) do
      %URI{scheme: scheme, host: host, port: port} ->
        host = String.downcase(host)
        port = port || default_port(scheme)
        port = if port == default_port(scheme), do: nil, else: port

        URI.to_string(%URI{scheme: scheme, host: host, port: port})

      :error ->
        nil
    end
  end

  def origin(_url), do: nil

  defp identity(url) do
    case uri(url) do
      %URI{scheme: scheme, host: host} = parsed ->
        {bare_host(host), parsed.port || default_port(scheme), scheme}

      :error ->
        :error
    end
  end

  defp default_pair?("http", 80, "https", 443), do: true
  defp default_pair?("https", 443, "http", 80), do: true
  defp default_pair?(_left_scheme, _left_port, _right_scheme, _right_port), do: false

  defp uri(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      uri
    else
      :error
    end
  end

  defp bare_host(host) do
    host = String.downcase(host)

    case String.split(host, ".", parts: 2) do
      ["www", rest] when rest != "" -> rest
      _ -> host
    end
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443
  defp default_port(_scheme), do: nil
end
