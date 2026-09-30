defmodule Crawler.URL do
  @moduledoc false

  @schemes ["http", "https"]

  def normalize(url) when is_binary(url) do
    case http_uri(url) do
      {:ok, uri} -> uri |> fold_uri() |> URI.to_string()
      :plain -> plain_normalize(url)
    end
  end

  @doc false
  def canonical(url) when is_binary(url) do
    case http_uri(url) do
      {:ok, uri} ->
        # The request keeps a directory slash. The store key drops it, so
        # `foo` and `foo/` are one page, while a fragment stays on the key
        # and does not match the fetched page.
        folded =
          uri
          |> fold_uri()
          |> URI.to_string()
          |> strip_trailing_slash()

        folded <> fragment_suffix(url)

      :plain ->
        plain_canonical(url)
    end
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

  defp http_uri(url) do
    uri = URI.parse(url)

    if uri.scheme in @schemes and is_binary(uri.host) and uri.host != "" do
      {:ok, uri}
    else
      :plain
    end
  end

  defp fold_uri(%URI{} = uri) do
    drop_default_port(%{
      uri
      | scheme: String.downcase(uri.scheme),
        host: String.downcase(uri.host),
        path: remove_dot_segments(uri.path),
        fragment: nil
    })
  end

  defp plain_normalize(url) do
    url
    |> URI.parse()
    |> Map.put(:fragment, nil)
    |> drop_default_port()
    |> URI.to_string()
  end

  defp plain_canonical(url) do
    {base, fragment} =
      case String.split(url, "#", parts: 2) do
        [base, fragment] -> {base, "#" <> fragment}
        [base] -> {base, ""}
      end

    {path, query} =
      case String.split(base, "?", parts: 2) do
        [path, query] -> {path, "?" <> query}
        [path] -> {path, ""}
      end

    String.trim_trailing(path, "/") <> query <> fragment
  end

  defp fragment_suffix(url) do
    case String.split(url, "#", parts: 2) do
      [_base, fragment] -> "#" <> fragment
      _ -> ""
    end
  end

  defp strip_trailing_slash(url) do
    {base, query} =
      case String.split(url, "?", parts: 2) do
        [base, query] -> {base, "?" <> query}
        [base] -> {base, ""}
      end

    String.trim_trailing(base, "/") <> query
  end

  # Drop `.` and `..` only. Percent-encoded dots stay encoded, and `...` is a
  # normal segment.
  defp remove_dot_segments(nil), do: nil

  defp remove_dot_segments(path) when is_binary(path) do
    absolute? = String.starts_with?(path, "/")
    # A final `.` or `..` names the directory, the same as a trailing slash.
    # `...` and percent-encoded dots are ordinary segments.
    trailing? = path != "/" and (String.ends_with?(path, "/") or final_dot_segment?(path))

    path
    |> path_segments(absolute?)
    |> Enum.reduce([], &push_segment/2)
    |> Enum.reverse()
    |> format_path(absolute?, trailing?)
  end

  defp path_segments(path, absolute?) do
    path =
      path
      |> String.trim_trailing("/")
      |> drop_one_leading_slash(absolute?)

    if path == "", do: [], else: String.split(path, "/")
  end

  defp drop_one_leading_slash("/" <> rest, true), do: rest
  defp drop_one_leading_slash(path, _absolute?), do: path

  defp final_dot_segment?(path) do
    path in [".", ".."] or String.ends_with?(path, "/.") or String.ends_with?(path, "/..")
  end

  defp push_segment(".", acc), do: acc
  defp push_segment("..", []), do: []
  defp push_segment("..", [_segment | acc]), do: acc
  defp push_segment(segment, acc), do: [segment | acc]

  defp format_path([], true, _trailing?), do: "/"
  defp format_path([], false, _trailing?), do: ""

  defp format_path(segments, absolute?, trailing?) do
    body = if absolute?, do: "/" <> Enum.join(segments, "/"), else: Enum.join(segments, "/")

    if trailing? and not String.ends_with?(body, "/") do
      body <> "/"
    else
      body
    end
  end

  defp disallowed?(link) do
    case URI.parse(link) do
      %URI{scheme: scheme} when is_binary(scheme) and scheme not in @schemes -> true
      _ -> false
    end
  end

  defp merge(link, base) do
    cond do
      scheme_absolute?(link) ->
        URI.parse(link)

      is_binary(base) and base != "" ->
        # Fold a dot segment in the base before merging. Elixir otherwise
        # leaves a "+" when the base path ends in `.` or `..`.
        URI.merge(merge_base(base), link)

      true ->
        URI.parse(link)
    end
  end

  defp merge_base(base) do
    case http_uri(base) do
      {:ok, _uri} -> normalize(base)
      :plain -> base
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
    {:ok, normalize(URI.to_string(%{uri | fragment: nil}))}
  end

  defp crawlable(_uri), do: :skip

  defp drop_default_port(%URI{scheme: "http", port: 80} = uri), do: %{uri | port: nil}
  defp drop_default_port(%URI{scheme: "https", port: 443} = uri), do: %{uri | port: nil}
  defp drop_default_port(uri), do: uri
end
