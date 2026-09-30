defmodule Crawler.Linker.Snapshot do
  @moduledoc """
  Builds one offline path for both the saved file and the links that point at it.
  """

  alias Crawler.Linker.PathOffliner
  alias Crawler.URL

  @port_marker "__port_"
  @colon_marker "__c_"
  @empty_marker "__e_"

  def path(url) when is_binary(url) do
    case URI.parse(URL.normalize(url)) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        uri
        |> logical_path()
        |> PathOffliner.transform()
        |> encode_segments()
        |> prefix_port(explicit_port(uri))

      _ ->
        url
    end
  end

  def relative(from_url, to_url) when is_binary(from_url) and is_binary(to_url) do
    directory = from_url |> path() |> drop_last_segment()
    depth = directory |> String.split("/", trim: true) |> length()

    String.duplicate("../", depth) <> path(to_url)
  end

  defp logical_path(%URI{host: host, path: path, query: query}) do
    segments =
      case path do
        binary when is_binary(binary) -> path_segments(binary)
        _ -> []
      end

    base = Enum.join([host | segments], "/")

    if is_binary(query) and query != "" do
      base <> "?" <> query
    else
      base
    end
  end

  defp path_segments(path) do
    path =
      path
      |> drop_one_leading_slash()
      |> String.trim_trailing("/")

    if path == "", do: [], else: String.split(path, "/")
  end

  defp drop_one_leading_slash("/" <> rest), do: rest
  defp drop_one_leading_slash(path), do: path

  defp drop_last_segment(path) do
    path
    |> String.split("/")
    |> Enum.drop(-1)
    |> Enum.join("/")
  end

  # `%` is already escaped by PathOffliner, so a marker's `%5F` is not encoded
  # again. Empty segments would otherwise collapse to the same file as a path
  # without them. The port marker is added after this step.
  defp encode_segments(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &encode_segment/1)
    |> encode_colons()
  end

  defp encode_segment(""), do: @empty_marker

  defp encode_segment(segment) do
    segment
    |> String.replace(@empty_marker, "__e%5F")
    |> String.replace(@port_marker, "__port%5F")
    |> String.replace(@colon_marker, "__c%5F")
  end

  defp encode_colons(path) do
    String.replace(path, ":", @colon_marker)
  end

  defp explicit_port(%URI{scheme: "http", port: 80}), do: nil
  defp explicit_port(%URI{scheme: "https", port: 443}), do: nil
  defp explicit_port(%URI{port: port}) when is_integer(port), do: port
  defp explicit_port(_uri), do: nil

  defp prefix_port(path, nil), do: path

  defp prefix_port(path, port) do
    case String.split(path, "/", parts: 2) do
      [host, rest] -> host <> @port_marker <> Integer.to_string(port) <> "/" <> rest
      [host] -> host <> @port_marker <> Integer.to_string(port)
    end
  end
end
