defmodule Crawler.Fetcher.Snapper do
  alias Crawler.Replacer

  @doc """
  ## Examples

      iex> Snapper.snap("hello", save_to: tmp("snapper"), url: "http://snapper.local/index.html")
      iex> File.read(tmp("snapper/snapper.local", "index.html"))
      {:ok, "hello"}

      iex> Snapper.snap("hello", save_to: "nope", url: "http://snapper.local/index.html")
      {:error, "Cannot write to file nope/snapper.local/index.html, reason: enoent"}

      iex> Snapper.snap("hello", save_to: tmp("snapper"), url: "http://snapper.local/hello")
      iex> File.read(tmp("snapper/snapper.local", "hello"))
      {:ok, "hello"}

      iex> Snapper.snap("hello", save_to: tmp("snapper"), url: "http://snapper.local/hello1/")
      iex> File.read(tmp("snapper/snapper.local", "hello1"))
      {:ok, "hello"}

      iex> Snapper.snap(
      iex>   "<a href='http://another.domain/page'></a>",
      iex>   save_to: tmp("snapper"),
      iex>   url: "http://snapper.local/depth0",
      iex>   level: 1,
      iex>   max_levels: 2,
      iex> )
      iex> File.read(tmp("snapper/snapper.local", "depth0"))
      {:ok, "<a href='another.domain/page'></a>"}

      iex> Snapper.snap(
      iex>   "<a href='https://another.domain:8888/page'></a>",
      iex>   save_to: tmp("snapper"),
      iex>   url: "http://snapper.local:7777/dir/depth1",
      iex>   level: 1,
      iex>   max_levels: 2,
      iex> )
      iex> File.read(tmp("snapper/snapper.local-7777/dir", "depth1"))
      {:ok, "<a href='../another.domain-8888/page'></a>"}
  """
  def snap(body, opts) do
    file_path = Path.join(opts[:save_to], snap_path(opts[:url]))

    if File.exists?(opts[:save_to]) do
      File.mkdir_p(Path.dirname(file_path))
    end

    {:ok, body} = Replacer.replace_links(body, opts)

    case File.write(file_path, body) do
      :ok              -> {:ok, opts}
      {:error, reason} -> {:error, "Cannot write to file #{file_path}, reason: #{reason}"}
    end
  end

  def snap_path(url) do
    url
    |> String.split("://", parts: 2)
    |> Enum.at(-1)
    |> String.replace(":", "-")
  end
end
