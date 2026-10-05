defmodule Crawler.URL.Authority do
  @moduledoc false

  alias Crawler.URL.Host

  @authority ~r/\A(?:[A-Za-z][A-Za-z0-9+.-]*:)?\/\/([^\/?#]*)/

  # URI.parse/1 drops malformed port text and accepts incomplete IPv6 syntax.
  # Validate the original text before rebuilding a URL from parsed fields.
  def parse(url, %URI{} = uri) when is_binary(url) do
    with [authority] <- Regex.run(@authority, url, capture: :all_but_first),
         host_port = authority |> String.split("@") |> List.last(),
         {:ok, host, port} <- host_port(host_port),
         true <- valid_port?(port) do
      {:ok, %{uri | host: host}}
    else
      _ -> :error
    end
  end

  defp host_port("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [host, tail] ->
        with {:ok, host} <- Host.ipv6(host),
             {:ok, port} <- port_tail(tail) do
          {:ok, host, port}
        end

      _ ->
        :error
    end
  end

  defp host_port(text) do
    case String.split(text, ":", parts: 2) do
      [host] -> domain(host, nil)
      [host, port] -> domain(host, port)
    end
  end

  defp domain(host, port) do
    case Host.domain(host) do
      {:ok, host} -> {:ok, host, port}
      :error -> :error
    end
  end

  defp port_tail(""), do: {:ok, nil}
  defp port_tail(":" <> port), do: {:ok, port}
  defp port_tail(_tail), do: :error

  defp valid_port?(nil), do: true
  defp valid_port?(""), do: true

  defp valid_port?(port) do
    Regex.match?(~r/\A[0-9]+\z/, port) and String.to_integer(port) <= 65_535
  end
end
