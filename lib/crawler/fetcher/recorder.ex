defmodule Crawler.Fetcher.Recorder do
  @moduledoc """
  Records information about each crawl for internal use.
  """

  alias Crawler.Store

  @doc """
  Records information about each crawl for internal use.

  ## Examples

      iex> Recorder.record(url: "url1", depth: 2)
      {:ok, %{depth: 3, url: "url1"}}

      iex> Recorder.record(url: "url2", depth: 2)
      iex> %Page{url: "url2", storage_revision: revision} = Store.find({"url2", nil})
      iex> is_reference(revision)
      true
  """
  def record(opts) do
    with opts <- Enum.into(opts, %{}),
         {:ok, _pid} <- store_url(opts),
         opts <- store_url_depth(opts) do
      {:ok, opts}
    end
  end

  @doc """
  Stores page data in `Crawler.Store.DB` for internal or external consumption, if enabled.

  ## Examples

      iex> Recorder.maybe_store_page("body", %{store: nil})
      {:ok, nil}

      iex> Recorder.record(url: "url", depth: 2)
      iex> {:ok, {%Page{url: "url", body: "body", opts: %{store: Store, url: "url", scope: nil}, storage_revision: current}, %Page{url: "url", body: nil, storage_revision: previous}}} =
      ...>   Recorder.maybe_store_page("body", %{store: Store, url: "url", scope: nil})
      iex> is_reference(current) and is_reference(previous) and current != previous
      true
  """
  def maybe_store_page(body, opts) do
    with true <- Store.current?(opts[:scope], opts[:generation], opts[:queue]),
         {:ok, _} = result <- store_page(body, opts),
         true <- Store.current?(opts[:scope], opts[:generation], opts[:queue]) do
      result
    else
      false -> {:error, :stale}
      error -> error
    end
  end

  @doc false
  def admitted(opts) do
    case store_url(opts) do
      {:ok, _} -> {:ok, store_url_depth(opts)}
      {:error, {:already_registered, _}} -> {:ok, store_url_depth(opts)}
      error -> error
    end
  end

  defp store_page(_body, %{store: nil} = _opts) do
    {:ok, nil}
  end

  defp store_page(body, %{store: Store} = opts) do
    result =
      Store.record_page_data({opts[:url], opts[:scope]}, body, opts)

    store_result(result)
  end

  defp store_page(body, opts) do
    case Store.claim_custom_storage(opts) do
      :skip -> {:ok, nil}
      :store -> custom_store_page(body, opts)
      error -> error
    end
  end

  defp custom_store_page(body, opts) do
    try do
      result =
        with true <- Store.current?(opts[:scope], opts[:generation], opts[:queue]),
             {:ok, _} = result <-
               store_result(opts[:store].add_page_data({opts[:url], opts[:scope]}, body, opts)),
             true <- Store.current?(opts[:scope], opts[:generation], opts[:queue]) do
          result
        else
          false -> {:error, :stale}
          error -> error
        end

      Store.finish_custom_storage(opts, match?({:ok, _}, result))
      result
    catch
      kind, reason ->
        Store.finish_custom_storage(opts, false)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp store_result(result) do
    case result do
      {:error, _} = error -> error
      result -> {:ok, result}
    end
  end

  defp store_url(opts) do
    Store.add(
      {opts[:url], opts[:scope]},
      opts[:generation],
      opts[:queue],
      opts[:html_tag],
      opts[:target_handle]
    )
  end

  defp store_url_depth(opts) do
    Map.replace!(opts, :depth, opts[:depth] + 1)
  end
end
