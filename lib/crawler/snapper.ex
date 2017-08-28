defmodule Crawler.Snapper do
  @moduledoc """
  Stores crawled pages offline.
  """

  alias __MODULE__.{LinkReplacer, DirMaker}

  @doc """
  In order to store pages offline, it provides the following functionalities:

  - replaces all URLs to their equivalent relative paths
  - creates directories when necessary to store the files

  ## Examples

      iex> Snapper.snap("hello", %{save_to: tmp("snapper"), url: "http://hello-world.local"})
      iex> File.read(tmp("snapper/hello-world.local", "index.html"))
      {:ok, "hello"}

      iex> Snapper.snap("hello", %{save_to: tmp("snapper"), url: "http://snapper.local/index.html"})
      iex> File.read(tmp("snapper/snapper.local", "index.html"))
      {:ok, "hello"}

      iex> Snapper.snap("hello", %{save_to: "nope", url: "http://snapper.local/index.html"})
      {:error, "Cannot write to file nope/snapper.local/index.html, reason: enoent"}

      iex> Snapper.snap("hello", %{save_to: tmp("snapper"), url: "http://snapper.local/hello"})
      iex> File.read(tmp("snapper/snapper.local/hello", "index.html"))
      {:ok, "hello"}

      iex> Snapper.snap("hello", %{save_to: tmp("snapper"), url: "http://snapper.local/hello1/"})
      iex> File.read(tmp("snapper/snapper.local/hello1", "index.html"))
      {:ok, "hello"}

      iex> Snapper.snap(
      iex>   "<a href='http://another.domain/page'></a>",
      iex>   %{
      iex>     save_to: tmp("snapper"),
      iex>     url: "http://snapper.local/depth0",
      iex>     depth: 1,
      iex>     max_depths: 2,
      iex>     html_tag: "a",
      iex>     content_type: "text/html",
      iex>   }
      iex> )
      iex> File.read(tmp("snapper/snapper.local/depth0", "index.html"))
      {:ok, "<a href='../../another.domain/page/index.html'></a>"}

      iex> Snapper.snap(
      iex>   "<a href='https://another.domain:8888/page'></a>",
      iex>   %{
      iex>     save_to: tmp("snapper"),
      iex>     url: "http://snapper.local:7777/dir/depth1",
      iex>     depth: 1,
      iex>     max_depths: 2,
      iex>     html_tag: "a",
      iex>     content_type: "text/html",
      iex>   }
      iex> )
      iex> File.read(tmp("snapper/snapper.local-7777/dir/depth1", "index.html"))
      {:ok, "<a href='../../../another.domain-8888/page/index.html'></a>"}
  """
  def snap(body, opts) do
    {:ok, body} = LinkReplacer.replace_links(body, opts)
    file_path   = DirMaker.make_dir(opts)

    case File.write(file_path, body) do
      :ok              -> {:ok, opts}
      {:error, reason} -> {:error, "Cannot write to file #{file_path}, reason: #{reason}"}
    end
  end
end
