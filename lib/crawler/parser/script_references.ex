defmodule Crawler.Parser.ScriptReferences do
  @moduledoc false

  alias Crawler.ImportMap
  alias Crawler.Linker
  alias Crawler.Parser.JsParser
  alias Crawler.Parser.JsParser.Calls
  alias Crawler.Parser.SourceMap
  alias Crawler.URL

  def list(source, opts) when is_binary(source) do
    goal = goal(opts)
    map = active_map(opts)
    {notes, sources} = map_additions(source, opts)

    spanned =
      (import_refs(source, goal, map, opts) ++ call_refs(source, goal, opts) ++ notes)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.at)
      |> Enum.sort_by(& &1.at)

    spanned ++ sources
  end

  def list(_source, _opts), do: []

  def elements(source, opts) when is_binary(source) do
    opts = Map.put(opts, :link_html_tag, "link")
    Enum.map(list(source, opts), &{:ref, &1})
  end

  def elements(_source, _opts), do: []

  def rewrite(source, opts) when is_binary(source) do
    page = opts[:url] || opts[:referrer_url]
    newline? = String.ends_with?(source, "\n")

    source
    |> list(opts)
    |> Enum.filter(&is_integer(&1[:at]))
    |> Enum.sort_by(& &1.at, :desc)
    |> Enum.reduce(source, fn ref, source ->
      replace(source, ref, replacement(ref, page, opts, newline?))
    end)
  end

  def rewrite(source, _opts), do: source

  defp map_additions(source, opts) do
    case SourceMap.javascript(source, opts) do
      nil -> {[], []}
      note -> {[SourceMap.annotation_ref(note, source)], SourceMap.data_source_refs(note, opts)}
    end
  end

  defp replacement(%{map_note: note}, page, opts, newline?) do
    SourceMap.rewrite_text(note, page, opts, :javascript, newline?)
  end

  defp replacement(ref, page, _opts, _newline?), do: offline(page, ref)

  defp import_refs(source, goal, map, opts) do
    source
    |> JsParser.specifier_spans(goal)
    |> Enum.filter(fn
      {:static, _at, _len, _spec} -> goal == :module
      {:dynamic, _at, _len, _spec} -> true
    end)
    |> Enum.map(fn {_kind, at, len, spec} -> import_ref(at, len, spec, map, opts) end)
  end

  defp call_refs(source, goal, opts) do
    source
    |> Calls.spans(goal)
    |> Enum.map(&call_ref(&1, opts))
  end

  defp import_ref(at, len, spec, map, opts) do
    case ImportMap.resolve(spec, map, script_base(opts)) do
      {:ok, url} ->
        %{
          at: at,
          len: len,
          spec: spec,
          url: url,
          goal: :module,
          html_tag: html_tag(opts),
          reference_tag: "script",
          import_map: child_map(opts, map),
          document_base: child_base(opts),
          worker_base: opts[:worker_base],
          credentials: import_credentials(opts)
        }

      _other ->
        nil
    end
  end

  defp call_ref({:url, at, len, spec}, opts) do
    case fetch(spec, script_base(opts)) do
      nil -> nil
      url -> file_ref(at, len, spec, url)
    end
  end

  defp call_ref({:worker, at, len, spec, goal, :window}, opts) do
    case fetch(spec, api_base(opts)) do
      nil -> nil
      url -> worker_ref(at, len, spec, url, goal, opts)
    end
  end

  defp call_ref({:worker, at, len, spec, goal, :module}, opts) do
    case fetch(spec, script_base(opts)) do
      nil -> nil
      url -> worker_ref(at, len, spec, url, goal, opts)
    end
  end

  defp call_ref({:scripts, at, len, spec}, %{worker_base: base} = opts) when is_binary(base) do
    case fetch(spec, base) do
      nil -> nil
      url -> script_ref(at, len, spec, url, opts)
    end
  end

  defp call_ref(_call, _opts), do: nil

  defp file_ref(at, len, spec, url) do
    %{
      at: at,
      len: len,
      spec: spec,
      url: url,
      goal: nil,
      html_tag: "link",
      reference_tag: "link",
      import_map: nil,
      document_base: nil,
      worker_base: nil
    }
  end

  defp worker_ref(at, len, spec, url, goal, opts) do
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
      credentials: :same_origin
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

  defp active_map(%{worker_base: base}) when is_binary(base), do: ImportMap.empty()
  defp active_map(opts), do: opts[:import_map] || ImportMap.empty()

  defp fetch(spec, base) do
    case URL.resolve(spec, base) do
      {:ok, url} -> url
      :skip -> nil
    end
  end

  defp script_base(opts), do: opts[:referrer_url] || opts[:document_base] || opts[:url] || ""
  defp api_base(opts), do: opts[:worker_base] || opts[:document_base] || script_base(opts)
  defp goal(opts), do: if(opts[:javascript_goal] == :script, do: :script, else: :module)
  defp html_tag(opts), do: opts[:link_html_tag] || "link"

  # A module graph keeps the entry crossorigin. import() from a classic script
  # is same-origin. Workers and importScripts set that mode on their own refs.
  defp import_credentials(opts) do
    if goal(opts) == :module, do: opts[:credentials] || :same_origin, else: :same_origin
  end

  defp offline(nil, ref), do: ref.url

  defp offline(page, ref) do
    Linker.offline_link(page, with_fragment(ref.url, ref.spec))
  end

  defp with_fragment(url, spec) do
    case String.split(spec, "#", parts: 2) do
      [_base, fragment] ->
        if String.contains?(url, "#"), do: url, else: url <> "#" <> fragment

      _split ->
        url
    end
  end

  defp replace(source, ref, replacement) do
    head = binary_part(source, 0, ref.at)
    tail = binary_part(source, ref.at + ref.len, byte_size(source) - ref.at - ref.len)
    head <> replacement <> tail
  end
end
