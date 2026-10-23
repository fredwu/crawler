defmodule Crawler.Parser.ScriptReferences do
  @moduledoc """
  Discovers script references from shared lexical facts.

  The former rewrite/2 API has been removed. Bind occurrences and render through
  Crawler.Analysis to select explicit local targets or safe online destinations.
  """

  alias Crawler.Analysis.Budget
  alias Crawler.ImportMap
  alias Crawler.Parser.JsParser
  alias Crawler.Parser.JsParser.Calls
  alias Crawler.Parser.SourceMap
  alias Crawler.URL

  def list(source, opts) when is_binary(source) do
    list(source, opts, JsParser.Scanner.scan(source, goal(opts)))
  end

  def list(_source, _opts), do: []

  def list(source, opts, scan) when is_binary(source) do
    {:ok, refs, _budget} =
      reduce(source, opts, scan, Budget.unlimited(), [], fn ref, refs, budget ->
        {:ok, [ref | refs], budget}
      end)

    Enum.reverse(refs)
  end

  def reduce(source, opts, scan, budget, acc, emit) when is_binary(source) do
    source_goal = goal(opts)

    with {:ok, budget} <- Budget.charge(budget, Budget.cost(:context)),
         {:ok, note, budget} <- source_map_note(source, opts, scan, budget),
         {:ok, imports, budget} <-
           JsParser.specifier_spans_result(source, source_goal, scan, budget),
         {:ok, calls, budget} <- Calls.spans_result(source, source_goal, scan, budget) do
      scratch =
        (length(imports) + length(calls) + 1) *
          (Budget.cost(:token) + Budget.cost(:map_entry) + Budget.cost(:list_cell, 6))

      with {:ok, budget} <- Budget.reserve(budget, scratch) do
        map = active_map(opts)

        descriptors =
          Enum.flat_map(imports, fn
            {:static, _, _, _} when source_goal != :module -> []
            {_kind, at, len, spec} -> [{at, {:import, at, len, spec}}]
          end) ++ Enum.map(calls, fn call -> {elem(call, 1), {:call, call}} end)

        descriptors =
          if note do
            at = if is_integer(note.at), do: note.at, else: byte_size(source)
            descriptors ++ [{at, {:note, note}}]
          else
            descriptors
          end

        descriptors =
          descriptors |> Enum.uniq_by(&elem(&1, 0)) |> Enum.sort_by(&elem(&1, 0))

        result =
          Enum.reduce_while(descriptors, {:ok, acc, budget}, fn {_at, descriptor},
                                                                {:ok, acc, budget} ->
            with {:ok, ref, budget} <- reference_result(descriptor, source, opts, map, budget),
                 {:ok, acc, budget} <- emit_ref(ref, acc, budget, emit) do
              {:cont, {:ok, acc, budget}}
            else
              error -> {:halt, error}
            end
          end)

        with {:ok, acc, budget} <- result,
             {:ok, acc, budget} <- map_sources(note, opts, budget, acc, emit),
             {:ok, budget} <- Budget.release(budget, scratch) do
          {:ok, acc, budget}
        end
      end
    end
  end

  defp source_map_note(source, opts, scan, budget) do
    case Map.fetch(opts, :source_map_note) do
      {:ok, note} -> {:ok, note, budget}
      :error -> SourceMap.javascript_result(source, opts, scan, budget)
    end
  end

  defp emit_ref(nil, acc, budget, _emit), do: {:ok, acc, budget}
  defp emit_ref(ref, acc, budget, emit), do: emit.(ref, acc, budget)

  defp map_sources(nil, _opts, budget, acc, _emit), do: {:ok, acc, budget}

  defp map_sources(note, opts, budget, acc, emit),
    do: SourceMap.reduce_data_source_refs(note, opts, budget, acc, emit)

  def elements(source, opts) when is_binary(source) do
    opts = Map.put(opts, :link_html_tag, "link")
    Enum.map(list(source, opts), &{:ref, &1})
  end

  def elements(_source, _opts), do: []

  defp reference_result({:note, note}, source, _opts, _map, budget) do
    with {:ok, _hypothetical} <- Budget.count(budget, :occurrences) do
      SourceMap.annotation_ref_result(note, source, budget)
    end
  end

  defp reference_result({:import, at, len, spec}, _source, opts, map, budget) do
    with {:ok, budget} <- reference_capacity(budget),
         result <- ImportMap.resolve_result(spec, map, script_base(opts), budget) do
      case result do
        {:ok, url, budget} -> {:ok, module_import_ref(at, len, spec, url, opts), budget}
        {:blocked, budget} -> {:ok, nil, budget}
        {:unmapped, budget} -> {:ok, nil, budget}
        error -> error
      end
    end
  end

  defp reference_result({:call, call}, _source, opts, _map, budget),
    do: call_ref_result(call, opts, budget)

  defp call_ref_result({:url, at, len, spec}, opts, budget) do
    resolve_call(spec, script_base(opts), budget, &file_ref(at, len, spec, &1, opts))
  end

  defp call_ref_result({:import, at, len, spec, base}, opts, budget) do
    resolve_call(
      spec,
      reference_base(base, opts),
      budget,
      &module_import_ref(at, len, spec, &1, opts)
    )
  end

  defp call_ref_result({:worker, at, len, spec, source_goal, base, credentials}, opts, budget) do
    resolve_call(
      spec,
      reference_base(base, opts),
      budget,
      &worker_ref(at, len, spec, &1, source_goal, credentials, opts)
    )
  end

  defp call_ref_result({:scripts, at, len, spec}, opts, budget),
    do: call_ref_result({:scripts, at, len, spec, :entry}, opts, budget)

  defp call_ref_result({:scripts, at, len, spec, base}, %{worker_base: worker} = opts, budget)
       when is_binary(worker) do
    resolve_call(spec, reference_base(base, opts), budget, &script_ref(at, len, spec, &1, opts))
  end

  defp call_ref_result(_call, _opts, budget), do: {:ok, nil, budget}

  defp resolve_call(_spec, base, budget, _build) when not is_binary(base),
    do: {:ok, nil, budget}

  defp resolve_call(spec, base, budget, build) do
    with {:ok, budget} <- reference_capacity(budget) do
      case URL.resolve_result(spec, base, budget) do
        {:ok, url, budget} -> {:ok, build.(url), budget}
        {:skip, budget} -> {:ok, nil, budget}
        error -> error
      end
    end
  end

  defp reference_capacity(budget) do
    with {:ok, _hypothetical} <- Budget.count(budget, :occurrences) do
      Budget.charge(budget, Budget.cost(:context) + Budget.cost(:token), facts: 1)
    end
  end

  defp module_import_ref(at, len, spec, url, opts) do
    %{
      at: at,
      len: len,
      spec: spec,
      url: url,
      goal: :module,
      html_tag: html_tag(opts),
      reference_tag: "script",
      import_map: child_map(opts, active_map(opts)),
      document_base: child_base(opts),
      document_url: child_document_url(opts),
      worker_base: opts[:worker_base],
      credentials: import_credentials(opts)
    }
  end

  defp file_ref(at, len, spec, url, opts) do
    %{
      at: at,
      len: len,
      spec: spec,
      url: url,
      goal: nil,
      html_tag: "link",
      reference_tag: "link",
      import_map: nil,
      document_base: child_base(opts),
      document_url: child_document_url(opts),
      worker_base: opts[:worker_base]
    }
  end

  defp worker_ref(at, len, spec, url, goal, credentials, opts) do
    %{
      at: at,
      len: len,
      spec: spec,
      url: url,
      goal: goal,
      html_tag: html_tag(opts),
      reference_tag: "script",
      import_map: nil,
      document_base: nil,
      worker_base: url,
      credentials: credentials
    }
  end

  defp script_ref(at, len, spec, url, opts) do
    %{
      at: at,
      len: len,
      spec: spec,
      url: url,
      goal: :script,
      html_tag: html_tag(opts),
      reference_tag: "script",
      import_map: nil,
      document_base: nil,
      worker_base: opts[:worker_base],
      credentials: :same_origin
    }
  end

  defp child_map(%{worker_base: base}, _map) when is_binary(base), do: nil
  defp child_map(_opts, map), do: map

  defp child_base(%{worker_base: base}) when is_binary(base), do: nil
  defp child_base(opts), do: opts[:document_base]

  defp child_document_url(%{worker_base: base}) when is_binary(base), do: nil
  defp child_document_url(opts), do: opts[:document_url]

  defp active_map(%{worker_base: base}) when is_binary(base), do: ImportMap.empty()
  defp active_map(opts), do: opts[:import_map] || ImportMap.empty()

  defp script_base(opts), do: opts[:referrer_url] || opts[:document_base] || opts[:url] || ""
  defp api_base(opts), do: opts[:worker_base] || opts[:document_base] || script_base(opts)

  defp reference_base(:window, opts), do: api_base(opts)
  defp reference_base(:script, opts), do: script_base(opts)
  defp reference_base(:entry, opts), do: opts[:worker_base]
  defp reference_base(:location, opts), do: location_base(opts)
  defp reference_base(:document, opts), do: document_base_url(opts)
  defp reference_base(_base, _opts), do: nil

  # `location` is the page after redirects. A worker's location is that worker.
  # It is not the script file and a base element does not change it.
  defp location_base(%{worker_base: base}) when is_binary(base), do: base
  defp location_base(%{document_url: url}) when is_binary(url), do: url
  defp location_base(opts), do: opts[:url] || ""

  # `document.baseURI` follows the page base. A worker has no document.
  defp document_base_url(%{worker_base: base}) when is_binary(base), do: nil
  defp document_base_url(%{document_base: base}) when is_binary(base), do: base
  defp document_base_url(opts), do: location_base(opts)
  defp goal(opts), do: if(opts[:javascript_goal] == :script, do: :script, else: :module)
  defp html_tag(opts), do: opts[:link_html_tag] || "link"

  # A module graph keeps the entry crossorigin. import() from a classic script
  # is same-origin. Workers and importScripts set that mode on their own refs.
  defp import_credentials(opts) do
    if goal(opts) == :module, do: opts[:credentials] || :same_origin, else: :same_origin
  end
end
