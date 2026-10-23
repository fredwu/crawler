defmodule Crawler.URL.Authority do
  @moduledoc false

  alias Crawler.URL.Host

  @authority ~r/\A(?:[A-Za-z][A-Za-z0-9+.-]*:)?\/\/([^\/?#]*)/

  # URI.parse/1 drops malformed port text and accepts incomplete IPv6 syntax.
  # Validate the original text before rebuilding a URL from parsed fields.
  def parse(url, %URI{} = uri) when is_binary(url) do
    case parse_result(url, uri, Crawler.Analysis.Budget.unlimited()) do
      {:ok, uri, _budget} -> {:ok, uri}
      {:invalid, _budget} -> :error
    end
  end

  @doc false
  def parse_result(url, %URI{} = uri, budget) when is_binary(url) do
    case Regex.run(@authority, url, capture: :all_but_first) do
      [authority] ->
        parse_authority(authority, uri, budget)

      _ ->
        {:invalid, budget}
    end
  end

  defp parse_authority(authority, uri, budget) do
    host_port = authority |> String.split("@") |> List.last()

    case host_port(host_port, budget) do
      {:ok, host, port, budget} ->
        if valid_port?(port),
          do: {:ok, %{uri | host: host}, budget},
          else: {:invalid, budget}

      {:invalid, budget} ->
        {:invalid, budget}

      {:error, _reason} = error ->
        error

      :error ->
        {:invalid, budget}
    end
  end

  defp host_port("[" <> rest, budget) do
    case String.split(rest, "]", parts: 2) do
      [host, tail] ->
        with {:ok, host} <- Host.ipv6(host),
             {:ok, port} <- port_tail(tail) do
          {:ok, host, port, budget}
        end

      _ ->
        :error
    end
  end

  defp host_port(text, budget) do
    case String.split(text, ":", parts: 2) do
      [host] -> domain(host, nil, budget)
      [host, port] -> domain(host, port, budget)
    end
  end

  defp domain(host, port, budget) do
    case Host.domain_result(host, budget) do
      {:ok, host, budget} -> {:ok, host, port, budget}
      {:invalid, budget} -> {:invalid, budget}
      {:error, _reason} = error -> error
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
