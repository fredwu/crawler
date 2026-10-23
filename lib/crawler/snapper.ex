defmodule Crawler.Snapper do
  @moduledoc """
  Publishes one standalone snapshot through the export filesystem boundary.

  Text input must be decoded UTF-8. Decode response bytes with
  [`Crawler.Charset.decode/2`](https://github.com/fredwu/crawler/blob/master/lib/crawler/charset.ex#L11) before calling this module. Opaque binary input is
  stored unchanged. HTML output has one UTF-8 byte-order mark; XHTML does not.

  Standalone references use resolved online destinations without URL userinfo.
  Saving another file does not bind a reference to that file. Managed exports
  must stage through their export owner.
  """

  require Logger

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.Diagnostics
  alias Crawler.Export.Filesystem
  alias Crawler.Export.Paths
  alias Crawler.MediaType
  alias Crawler.Parser
  alias Crawler.Parser.Prepared

  @utf8_bom <<0xEF, 0xBB, 0xBF>>
  @managed_keys [:generation, :execution_lease, :scheduler_claim]

  @doc """
  Atomically publishes one file below an existing isolated `:save_to` root.

  The caller must supply an opaque `:public_id` accepted by
  [`Crawler.Export.Paths.artifact/2`](https://github.com/fredwu/crawler/blob/master/lib/crawler/export/paths.ex#L43). The response content type selects the suffix,
  including `.bin` for an unknown type. Use a distinct ID for each response or
  interpretation variant. Reusing an ID and content type replaces that file.

  Returns `{:ok, %{public_id: id, path: relative_path}}` after publication and
  cleanup. This is a per-file acknowledgement, not archive readiness. Open the
  file with `Path.join(save_to, result.path)`. Concurrent writers can receive
  `:destination_owned`; this function does not retry.

  Filesystem failures return `{:error, {:snapshot, operation, reason}}`. A cleanup
  failure includes its private recovery receipt. Keep that receipt private and
  use it only under the filesystem recovery contract. Parse, render, and analysis
  budget errors pass through unchanged.

  Managed or stale managed calls return
  `{:error, {:snapshot, :managed_export_required}}` before parsing or writing.
  A `Prepared` value reuses its authoritative analysis and occurrence collection.

  An optional `:before_publish` callback runs after staging and before final
  validation and rename. Its return is ignored. Exceptions propagate after
  staging cleanup.
  """
  def snap(%Prepared{} = prepared, opts) do
    with :ok <- standalone(opts, prepared.opts),
         {:ok, path} <- artifact_path(opts),
         :ok <- root(opts[:save_to]),
         {:ok, body, budget} <- render(prepared) do
      publish(body, budget, path, opts)
    end
  end

  def snap(body, opts) do
    with :ok <- standalone(opts, nil),
         {:ok, _path} <- artifact_path(opts),
         :ok <- root(opts[:save_to]),
         {:ok, prepared} <- Parser.prepare_for_parse(body, opts),
         do: snap(prepared, opts)
  end

  defp standalone(opts, prepared_opts) do
    if managed?(opts) or managed?(prepared_opts) or
         not is_nil(Process.get(:crawler_execution_lease)),
       do: {:error, {:snapshot, :managed_export_required}},
       else: :ok
  end

  defp managed?(nil), do: false
  defp managed?(opts), do: Enum.any?(@managed_keys, &(not is_nil(opts[&1])))

  defp artifact_path(opts) do
    case Paths.artifact(opts[:public_id], opts[:content_type]) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> {:error, {:snapshot, :path, reason}}
    end
  end

  defp root(root) when is_binary(root) and root != "" do
    if String.valid?(root) and not String.contains?(root, <<0>>),
      do: :ok,
      else: {:error, {:snapshot, :acquire, :invalid_root}}
  end

  defp root(_root), do: {:error, {:snapshot, :acquire, :invalid_root}}

  defp render(%Prepared{analysis: nil, source: source}), do: {:ok, source, nil}

  defp render(%Prepared{analysis: analysis, collection: collection}) do
    with {:ok, body, stats} <-
           Analysis.render_with_stats(analysis, collection, &Analysis.online_fallback/1),
         do: {:ok, body, struct!(Budget, stats.budget)}
  end

  defp publish(body, budget, path, opts) do
    case Filesystem.acquire_file(opts[:save_to], path) do
      {:ok, filesystem, receipt} ->
        result =
          try do
            stage_and_publish(filesystem, body, budget, path, opts)
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end

        cleanup = Filesystem.abort(filesystem)
        finish(result, cleanup, receipt, opts)

      {:error, reason} ->
        write_error(:acquire, reason, opts)
    end
  end

  defp stage_and_publish(filesystem, body, budget, path, opts) do
    bom? =
      MediaType.html?(opts[:content_type]) and not MediaType.xhtml?(opts[:content_type]) and
        not String.starts_with?(body, @utf8_bom)

    bytes = byte_size(body) + if(bom?, do: byte_size(@utf8_bom), else: 0)

    with {:ok, ticket} <-
           filesystem_result(Filesystem.reserve(filesystem, :archive, path, bytes), :write, opts),
         {:ok, body} <- snapshot_body(body, budget, bom?),
         :ok <- filesystem_result(Filesystem.write(filesystem, ticket, body), :write, opts),
         _ <- before_publish(opts),
         {:ok, prepared} <- filesystem_result(Filesystem.prepare(filesystem), :prepare, opts),
         :ok <- filesystem_result(Filesystem.promote(prepared), :rename, opts) do
      {:ok, %{public_id: opts[:public_id], path: path}}
    end
  end

  defp snapshot_body(body, _budget, false), do: {:ok, body}
  defp snapshot_body(body, nil, true), do: {:ok, @utf8_bom <> body}

  defp snapshot_body(body, budget, true) do
    with {:ok, _budget} <-
           Budget.charge(budget, byte_size(body) + byte_size(@utf8_bom) + Budget.cost(:binary)),
         do: {:ok, @utf8_bom <> body}
  end

  defp before_publish(%{before_publish: fun}) when is_function(fun, 0), do: fun.()
  defp before_publish(_opts), do: :ok

  defp finish({:raised, kind, reason, stacktrace}, _cleanup, _receipt, _opts),
    do: :erlang.raise(kind, reason, stacktrace)

  defp finish(result, {:ok, _placement}, _receipt, _opts), do: result

  defp finish(_result, {:error, reason}, receipt, opts),
    do: write_error(:cleanup, {reason, receipt}, opts)

  defp filesystem_result({:error, reason}, operation, opts),
    do: write_error(operation, reason, opts)

  defp filesystem_result(result, _operation, _opts), do: result

  defp write_error(operation, reason, opts) do
    category = if is_atom(reason), do: reason, else: :filesystem_failure

    Logger.error("Snapshot #{operation} failed for #{Diagnostics.url(opts[:url])}: #{category}")

    {:error, {:snapshot, operation, reason}}
  end
end
