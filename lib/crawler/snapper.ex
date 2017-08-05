defmodule Crawler.Snapper do
  alias Crawler.{Replacer, Linker.Pathfinder}

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
      iex>   depth: 1,
      iex>   max_depths: 2,
      iex> )
      iex> File.read(tmp("snapper/snapper.local", "depth0"))
      {:ok, "<a href='../another.domain/page'></a>"}

      iex> Snapper.snap(
      iex>   "<a href='https://another.domain:8888/page'></a>",
      iex>   save_to: tmp("snapper"),
      iex>   url: "http://snapper.local:7777/dir/depth1",
      iex>   depth: 1,
      iex>   max_depths: 2,
      iex> )
      iex> File.read(tmp("snapper/snapper.local-7777/dir", "depth1"))
      {:ok, "<a href='../../another.domain-8888/page'></a>"}
  """
  def snap(body, opts) do
    {:ok, body} = update_links(body, opts)
    file_path   = create_snap_dir(opts)

    case File.write(file_path, body) do
      :ok              -> {:ok, opts}
      {:error, reason} -> {:error, "Cannot write to file #{file_path}, reason: #{reason}"}
    end
  end

  defp update_links(body, opts) do
    if opts[:depth] < opts[:max_depths] do
      Replacer.replace_links(body, opts)
    else
      {:ok, body}
    end
  end

  defp create_snap_dir(opts) do
    file_path = Path.join(opts[:save_to], Pathfinder.find_path(opts[:url]))

    if File.exists?(opts[:save_to]) do
      File.mkdir_p(Path.dirname(file_path))
    end

    file_path
  end
end
