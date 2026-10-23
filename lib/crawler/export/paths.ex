defmodule Crawler.Export.Paths do
  @moduledoc false

  alias Crawler.MediaType

  @extensions %{
    "text/html" => ".html",
    "application/xhtml+xml" => ".xhtml",
    "text/css" => ".css",
    "image/svg+xml" => ".svg",
    "application/json" => ".json",
    "application/manifest+json" => ".webmanifest",
    "application/xml" => ".xml",
    "text/xml" => ".xml",
    "application/rss+xml" => ".xml",
    "application/atom+xml" => ".xml",
    "text/plain" => ".txt",
    "text/csv" => ".csv",
    "text/vtt" => ".vtt",
    "image/png" => ".png",
    "image/jpeg" => ".jpg",
    "image/gif" => ".gif",
    "image/webp" => ".webp",
    "image/avif" => ".avif",
    "image/x-icon" => ".ico",
    "font/woff" => ".woff",
    "font/woff2" => ".woff2",
    "font/ttf" => ".ttf",
    "font/otf" => ".otf",
    "application/pdf" => ".pdf",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => ".docx",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => ".xlsx",
    "application/wasm" => ".wasm",
    "audio/mpeg" => ".mp3",
    "audio/ogg" => ".ogg",
    "video/mp4" => ".mp4",
    "video/webm" => ".webm"
  }

  def public_id?(id),
    do: is_binary(id) and byte_size(id) in 24..64 and Regex.match?(~r/\A[a-z0-9]+\z/, id)

  def artifact(id, content_type) do
    if public_id?(id),
      do: {:ok, "resources/" <> id <> extension(content_type)},
      else: {:error, :invalid_public_id}
  end

  def extension(type) do
    type = content_type(type)
    if MediaType.javascript?(type), do: ".js", else: Map.get(@extensions, type, ".bin")
  end

  def content_type(type) when is_binary(type) do
    normalized = MediaType.normalize(type)

    if byte_size(normalized) <= 127 and
         Regex.match?(~r/\A[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+\z/, normalized),
       do: normalized,
       else: nil
  end

  def content_type(_type), do: nil

  def relative(from, to) do
    with true <- relative_file?(from),
         true <- relative_file?(to),
         true <- Path.dirname(from) == "resources" and Path.dirname(to) == "resources" do
      {:ok, "./" <> Path.basename(to)}
    else
      _ -> {:error, :invalid_artifact_path}
    end
  end

  def relative_file?(path) when is_binary(path) do
    byte_size(path) in 1..240 and Regex.match?(~r/\A[a-z0-9._\/-]+\z/, path) and
      not String.starts_with?(path, "/") and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."] and byte_size(&1) <= 128))
  end

  def relative_file?(_path), do: false

  def online(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, URI.to_string(%{uri | userinfo: nil, fragment: nil})}

      _ ->
        {:error, :invalid_online_target}
    end
  rescue
    ArgumentError -> {:error, :invalid_online_target}
  end

  def online(_url), do: {:error, :invalid_online_target}
end
