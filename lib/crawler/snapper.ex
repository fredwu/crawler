defmodule Crawler.Snapper do
  @moduledoc """
  Stores crawled pages offline.
  """

  require Logger

  alias Crawler.Diagnostics
  alias Crawler.MediaType
  alias Crawler.Snapper.DirMaker
  alias Crawler.Snapper.LinkReplacer
  alias Crawler.Snapper.Staging
  alias Crawler.Store

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  @doc """
  In order to store pages offline, it provides the following functionalities:

  - replaces all URLs to their equivalent relative paths
  - creates directories when necessary to store the files
  - marks saved HTML as UTF-8 with a byte-order mark

  ## Examples

      iex> Snapper.snap("hello", %{save_to: tmp("snapper"), url: "http://hello-world.local", content_type: "text/html"})
      iex> File.read(tmp("snapper/hello-world.local", "__index.html"))
      {:ok, <<0xEF, 0xBB, 0xBF, "hello">>}

      iex> Snapper.snap("hello", %{save_to: tmp("snapper"), url: "http://snapper.local/index.html", content_type: "text/html"})
      iex> File.read(tmp("snapper/snapper.local", "index.html"))
      {:ok, <<0xEF, 0xBB, 0xBF, "hello">>}

      iex> Snapper.snap("hello", %{save_to: "nope", url: "http://snapper.local/index.html"})
      {:error, {:snapshot, :write, :enoent}}

      iex> Snapper.snap("hello", %{save_to: tmp("snapper"), url: "http://snapper.local/hello", content_type: "text/html"})
      iex> File.read(tmp("snapper/snapper.local/hello", "__index.html"))
      {:ok, <<0xEF, 0xBB, 0xBF, "hello">>}

      iex> Snapper.snap("hello", %{save_to: tmp("snapper"), url: "http://snapper.local/hello1/", content_type: "text/html"})
      iex> File.read(tmp("snapper/snapper.local/hello1", "__index.html"))
      {:ok, <<0xEF, 0xBB, 0xBF, "hello">>}

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
      {:ok, <<0xEF, 0xBB, 0xBF, "<a href='../../another.domain/page/__index.html'></a>">>}

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
      {:ok, <<0xEF, 0xBB, 0xBF, "<a href='../../../another.domain__port_8888__scheme_https/page/__index.html'></a>">>}
  """
  def snap(body, opts) do
    {:ok, body} = LinkReplacer.replace_links(body, opts)
    body = snapshot_body(body, opts)
    file_path = DirMaker.make_dir(opts)

    if publish?(opts) do
      publish(body, file_path, opts)
    else
      write_file(file_path, body, opts)
    end
  end

  defp snapshot_body(body, opts) do
    if MediaType.html?(opts[:content_type]) and not MediaType.xhtml?(opts[:content_type]) and
         not String.starts_with?(body, @utf8_bom) do
      @utf8_bom <> body
    else
      body
    end
  end

  defp publish?(opts) do
    not is_nil(opts[:generation]) and not is_nil(opts[:scope])
  end

  defp publish(body, file_path, opts) do
    temp = Path.join(Path.dirname(file_path), Staging.filename())

    watcher = watch_temp(temp)

    try do
      case File.write(temp, body) do
        :ok ->
          before_publish(opts)
          publish_temp(temp, file_path, opts)

        {:error, reason} ->
          write_error(:write, reason, opts)
      end
    after
      finish_temp(watcher)
    end
  end

  defp before_publish(%{before_publish: fun}) when is_function(fun, 0), do: fun.()
  defp before_publish(_opts), do: :ok

  defp watch_temp(temp) do
    worker = self()

    # A killed caller skips `after`; its monitor still triggers staging cleanup.
    spawn_monitor(fn ->
      ref = Process.monitor(worker)

      receive do
        {:finished, ^worker} -> :ok
        {:DOWN, ^ref, :process, ^worker, _} -> :ok
      end

      File.rm(temp)
    end)
  end

  defp finish_temp({watcher, ref}) do
    send(watcher, {:finished, self()})

    receive do
      {:DOWN, ^ref, :process, ^watcher, _} -> :ok
    end
  end

  defp publish_temp(temp, file_path, opts) do
    case Store.publish_file(opts[:scope], opts[:generation], file_path, temp, opts[:queue]) do
      :ok ->
        {:ok, opts}

      {:error, :stale} = error ->
        error

      {:error, {:snapshot, operation, reason}} ->
        write_error(operation, reason, opts)
    end
  end

  defp write_file(file_path, body, opts) do
    case File.write(file_path, body) do
      :ok -> {:ok, opts}
      {:error, reason} -> write_error(:write, reason, opts)
    end
  end

  defp write_error(operation, reason, opts) do
    Logger.error("Snapshot #{operation} failed for #{Diagnostics.url(opts[:url])}: #{reason}")
    {:error, {:snapshot, operation, reason}}
  end
end
