defmodule Crawler.Snapper do
  @moduledoc """
  Stores crawled pages offline.
  """

  require Logger

  alias Crawler.Snapper.DirMaker
  alias Crawler.Snapper.LinkReplacer
  alias Crawler.Store

  @doc """
  In order to store pages offline, it provides the following functionalities:

  - replaces all URLs to their equivalent relative paths
  - creates directories when necessary to store the files

  ## Examples

      iex> Snapper.snap("hello", %{save_to: tmp("snapper"), url: "http://hello-world.local"})
      iex> File.read(tmp("snapper/hello-world.local", "__index.html"))
      {:ok, "hello"}

      iex> Snapper.snap("hello", %{save_to: tmp("snapper"), url: "http://snapper.local/index.html"})
      iex> File.read(tmp("snapper/snapper.local", "index.html"))
      {:ok, "hello"}

      iex> Snapper.snap("hello", %{save_to: "nope", url: "http://snapper.local/index.html"})
      {:error, "Cannot write to file nope/snapper.local/index.html, reason: enoent"}

      iex> Snapper.snap("hello", %{save_to: tmp("snapper"), url: "http://snapper.local/hello"})
      iex> File.read(tmp("snapper/snapper.local/hello", "__index.html"))
      {:ok, "hello"}

      iex> Snapper.snap("hello", %{save_to: tmp("snapper"), url: "http://snapper.local/hello1/"})
      iex> File.read(tmp("snapper/snapper.local/hello1", "__index.html"))
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
      iex> File.read(tmp("snapper/snapper.local/depth0", "__index.html"))
      {:ok, "<a href='../../another.domain/page/__index.html'></a>"}

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
      iex> File.read(tmp("snapper/snapper.local__port_7777/dir/depth1", "__index.html"))
      {:ok, "<a href='../../../another.domain__port_8888__scheme_https/page/__index.html'></a>"}
  """
  def snap(body, opts) do
    {:ok, body} = LinkReplacer.replace_links(body, opts)
    file_path = DirMaker.make_dir(opts)

    if publish?(opts) do
      publish(body, file_path, opts)
    else
      write_file(file_path, body, opts)
    end
  end

  defp publish?(opts) do
    is_integer(opts[:generation]) and not is_nil(opts[:scope])
  end

  defp publish(body, file_path, opts) do
    temp =
      Path.join(
        Path.dirname(file_path),
        ".#{Path.basename(file_path)}.#{System.unique_integer([:positive])}.tmp"
      )

    # An external exit skips `rescue` and `after`, so this process removes the
    # temp file when the worker dies.
    watch_temp(temp)

    case File.write(temp, body) do
      :ok ->
        try do
          before_publish(opts)
          publish_temp(temp, file_path, opts)
        rescue
          exception ->
            File.rm(temp)
            reraise exception, __STACKTRACE__
        end

      {:error, reason} ->
        write_error(file_path, reason)
    end
  end

  defp before_publish(%{before_publish: fun}) when is_function(fun, 0), do: fun.()
  defp before_publish(_opts), do: :ok

  defp watch_temp(temp) do
    worker = self()

    spawn(fn ->
      ref = Process.monitor(worker)

      receive do
        {:DOWN, ^ref, _, _, _} -> File.rm(temp)
      end
    end)
  end

  defp publish_temp(temp, file_path, opts) do
    case Store.publish_file(opts[:scope], opts[:generation], file_path, temp) do
      :ok ->
        {:ok, opts}

      {:error, :stale} = error ->
        File.rm(temp)
        error

      {:error, message} = error ->
        File.rm(temp)
        Logger.error(message)
        error
    end
  end

  defp write_file(file_path, body, opts) do
    case File.write(file_path, body) do
      :ok -> {:ok, opts}
      {:error, reason} -> write_error(file_path, reason)
    end
  end

  defp write_error(file_path, reason) do
    message = "Cannot write to file #{file_path}, reason: #{reason}"
    Logger.error(message)
    {:error, message}
  end
end
