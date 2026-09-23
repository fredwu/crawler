defmodule Crawler.URL do
  @moduledoc false

  @schemes ["http", "https"]

  def normalize(url) when is_binary(url) do
    url
    |> URI.parse()
    |> stringify()
  end

  def resolve(link, base) when is_binary(link) do
    link = String.trim(link)

    cond do
      link == "" ->
        :skip

      disallowed?(link) ->
        :skip

      true ->
        link
        |> merge(base)
        |> crawlable()
    end
  end

  def resolve(_link, _base), do: :skip

  defp disallowed?(link) do
    case URI.parse(link) do
      %URI{scheme: scheme} when is_binary(scheme) and scheme not in @schemes -> true
      _ -> false
    end
  end

  defp merge(link, base) do
    cond do
      scheme_absolute?(link) -> URI.parse(link)
      is_binary(base) and base != "" -> URI.merge(base, link)
      true -> URI.parse(link)
    end
  end

  defp scheme_absolute?(link) do
    case URI.parse(link) do
      %URI{scheme: scheme, host: host} when scheme in @schemes and is_binary(host) -> true
      _ -> false
    end
  end

  defp crawlable(%URI{scheme: scheme, host: host} = uri)
       when scheme in @schemes and is_binary(host) do
    {:ok, stringify(uri)}
  end

  defp crawlable(_uri), do: :skip

  defp stringify(uri) do
    uri
    |> Map.put(:fragment, nil)
    |> drop_default_port()
    |> URI.to_string()
  end

  defp drop_default_port(%URI{scheme: "http", port: 80} = uri), do: %{uri | port: nil}
  defp drop_default_port(%URI{scheme: "https", port: 443} = uri), do: %{uri | port: nil}
  defp drop_default_port(uri), do: uri
end
