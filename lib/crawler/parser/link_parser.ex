defmodule Crawler.Parser.LinkParser do
  @moduledoc """
  Parses links and transforms them if necessary.
  """

  alias Crawler.HTMLReferences
  alias Crawler.HTMLRefresh
  alias Crawler.MediaType
  alias Crawler.Parser.CssParser
  alias Crawler.Parser.LinkParser.LinkExpander
  alias Crawler.Parser.ScriptReferences
  alias Crawler.Parser.SourceMap
  alias Crawler.Parser.SpeculationRules
  alias Crawler.Parser.Srcset

  @doc """
  Parses links and transforms them if necessary.

  ## Examples

      iex> LinkParser.parse(
      iex>   {"a", [{"hello", "world"}, {"href", "http://hello.world"}], []},
      iex>   %{},
      iex>   &Kernel.inspect(&1, Enum.into(&2, []))
      iex> )
      "{\\\"href\\\", \\\"http://hello.world\\\"}"

      iex> LinkParser.parse(
      iex>   {"img", [{"hello", "world"}, {"src", "http://hello.world"}], []},
      iex>   %{assets: ["images"]},
      iex>   &Kernel.inspect(&1, Enum.into(&2, []))
      iex> )
      "{\\\"src\\\", \\\"http://hello.world\\\"}"
  """
  def parse(
        %{name: tag, attributes: attrs, children: children, namespace: namespace},
        opts,
        handler
      ) do
    emit(tag, attrs, children, opts, handler, namespace)
  end

  def parse({tag, attrs, children}, opts, handler) do
    emit(tag, attrs, children, opts, handler, :html)
  end

  def parse({:ref, ref}, opts, handler), do: ref_result(ref, opts, handler)

  defp emit(tag, attrs, children, opts, handler, namespace) do
    {refs, plain} =
      tag
      |> links(attrs, children, opts, namespace)
      |> Enum.split_with(&match?({:ref, _}, &1))

    results =
      plain
      |> Enum.map(fn {attr, link} ->
        {role, reference_tag, fetch_kind} = reference_identity(tag, attr, attrs, namespace)
        goal = reference_goal(tag, attr, link, attrs, opts, namespace)
        goal = if fetch_kind, do: nil, else: goal
        expanded = LinkExpander.expand({attr_name(attr), link}, opts)
        {role, reference_tag, goal, fetch_kind, expanded}
      end)
      |> Enum.reject(&match?({_role, _reference_tag, _goal, _fetch_kind, nil}, &1))
      |> Enum.uniq_by(fn {role, reference_tag, goal, fetch_kind, element} ->
        {role, reference_tag, goal, fetch_kind, raw_link(element)}
      end)
      |> Enum.map(fn {role, reference_tag, goal, fetch_kind, element} ->
        link_opts = handler_opts(opts, role, goal, reference_tag, fetch_kind)
        handler.(element, worker_entry_opts(link_opts, tag, attrs, namespace, element))
      end)

    results = results ++ Enum.map(refs, fn {:ref, ref} -> ref_result(ref, opts, handler) end)

    case srcdoc_links(tag, attrs, opts, handler, namespace) do
      [] -> normalize_results(results)
      extra -> combine_results(normalize_results(results), extra)
    end
  end

  defp normalize_results([]), do: nil
  defp normalize_results([result]), do: result
  defp normalize_results(results), do: results

  defp combine_results(nil, [result]), do: result
  defp combine_results(nil, extra), do: extra
  defp combine_results(result, extra) when not is_list(result), do: [result | extra]
  defp combine_results(results, extra), do: results ++ extra

  defp links(tag, attrs, children, opts, namespace) do
    attributes =
      tag
      |> HTMLReferences.attributes(attrs, opts, namespace)
      |> Enum.flat_map(fn name -> attribute_links(name, HTMLReferences.attribute(attrs, name)) end)

    drop_same_drawing(
      attributes ++ source_links(tag, attrs, children, opts, namespace),
      tag,
      namespace
    )
  end

  defp drop_same_drawing(links, tag, :svg) do
    Enum.reject(links, &same_drawing?(&1, tag))
  end

  defp drop_same_drawing(links, _tag, _namespace), do: links

  defp same_drawing?({attr, value}, tag) do
    HTMLReferences.local_reference?(value) and
      (attr in ["style", "style_text"] or HTMLReferences.presentation_attribute?(attr) or
         HTMLReferences.role(tag, attr, []) == "img")
  end

  defp same_drawing?(_link, _tag), do: false

  defp source_links("style", attrs, children, opts, namespace) when namespace in [:html, :svg] do
    if HTMLReferences.enabled?(opts, "css") and HTMLReferences.css_style_element?(attrs) do
      text = raw_text(children)
      style_links(text, "style_text") ++ SourceMap.element_refs(text, opts, :css)
    else
      []
    end
  end

  defp source_links("script", attrs, children, opts, :html) do
    cond do
      HTMLReferences.speculation_rules?(attrs) ->
        if HTMLReferences.attribute(attrs, "src") == nil do
          speculation_links(children, opts)
        else
          []
        end

      HTMLReferences.enabled?(opts, "js") and HTMLReferences.script_source(attrs) == :inline ->
        inline_script_links(attrs, children, opts)

      true ->
        []
    end
  end

  defp source_links("script", attrs, children, opts, :svg) do
    if HTMLReferences.enabled?(opts, "js") and HTMLReferences.svg_script_source(attrs) == :inline do
      inline_script_links(attrs, children, opts)
    else
      []
    end
  end

  defp source_links(_tag, _attrs, _children, _opts, _namespace), do: []

  defp srcdoc_links("iframe", attrs, opts, handler, :html) do
    case HTMLReferences.attribute(attrs, "srcdoc") do
      nil ->
        []

      srcdoc ->
        opts =
          opts
          |> Map.delete(:robots_nofollow)
          |> Map.delete(:headers)
          |> Map.delete(:javascript_goal)
          |> Map.delete(:import_map)
          |> Map.delete(:document_base)
          |> Map.delete(:worker_base)
          |> Map.delete(:fetch_kind)
          |> Map.delete(:json_span)
          |> Map.put(:content_type, "text/html")
          |> Map.put(:html_tag, "a")

        Crawler.Parser.parse_links(srcdoc, opts, handler)
    end
  end

  defp srcdoc_links(_tag, _attrs, _opts, _handler, _namespace), do: []

  defp inline_script_links(attrs, children, opts) do
    opts =
      opts
      |> Map.put(:link_html_tag, "script")
      |> Map.put(:javascript_goal, HTMLReferences.script_goal(attrs))

    children
    |> raw_text()
    |> ScriptReferences.list(opts)
    |> Enum.map(&{:ref, &1})
  end

  defp speculation_links(children, opts) do
    children
    |> raw_text()
    |> SpeculationRules.entries(opts)
    |> Enum.map(fn {raw, url, _start, _length} -> {:ref, page_ref(raw, url)} end)
  end

  defp page_ref(raw, url) do
    %{
      spec: raw,
      url: url,
      goal: nil,
      html_tag: "a",
      reference_tag: "a",
      import_map: nil,
      document_base: nil,
      worker_base: nil
    }
  end

  defp attribute_links(_name, nil), do: []
  defp attribute_links("style", value), do: style_links(value, "style")

  defp attribute_links(name, value) when name in ["srcset", "imagesrcset"] do
    value
    |> Srcset.urls()
    |> Enum.reject(&String.match?(&1, ~r/^data:/i))
    |> Enum.map(&{name, &1})
  end

  defp attribute_links("content", value) do
    case HTMLRefresh.target(value) do
      %{url: url} -> [{"content", url}]
      nil -> []
    end
  end

  defp attribute_links(name, value) do
    if HTMLReferences.presentation_attribute?(name),
      do: style_links(value, name),
      else: [{name, value}]
  end

  defp style_links(nil, _attr), do: []
  defp style_links("", _attr), do: []

  defp style_links(css, attr) do
    css
    |> CssParser.parse()
    |> Enum.map(fn {"link", [{"href", url}], _} -> {attr, url} end)
  end

  defp reference_goal(tag, attr, link, attrs, opts, namespace) do
    cond do
      MediaType.javascript?(opts[:content_type]) ->
        :module

      tag == "script" and namespace == :svg and attr == "xlink:href" ->
        HTMLReferences.script_goal(attrs)

      tag == "script" and namespace == :svg and attr == "href" and
          HTMLReferences.attribute(attrs, "href") == link ->
        HTMLReferences.script_goal(attrs)

      tag == "script" and attr == "href" ->
        :module

      tag == "script" and attr == "src" ->
        HTMLReferences.script_goal(attrs)

      tag == "link" and attr == "href" and HTMLReferences.role(tag, attr, attrs) == "script" ->
        HTMLReferences.preload_goal(attrs)

      true ->
        nil
    end
  end

  defp reference_identity(_tag, attr, _attrs, :math) when attr in ["href", "xlink:href"],
    do: {"a", "a", nil}

  defp reference_identity("link", "href", attrs, :html) do
    case HTMLReferences.link_choice(attrs) do
      %{html_tag: html_tag, reference_tag: reference_tag, fetch_kind: fetch_kind} ->
        {html_tag, reference_tag, fetch_kind}

      :skip ->
        {"link", "link", nil}
    end
  end

  defp reference_identity("script", "src", attrs, :html) do
    if HTMLReferences.speculation_rules?(attrs) do
      {"link", "link", :speculation_rules}
    else
      {"script", "script", nil}
    end
  end

  defp reference_identity(tag, attr, attrs, _namespace),
    do: {HTMLReferences.role(tag, attr, attrs), tag, nil}

  defp worker_entry_opts(opts, "link", attrs, :html, element) do
    if HTMLReferences.worker_entry?(attrs) do
      Map.put(opts, :worker_base, expanded_url(element))
    else
      opts
    end
  end

  defp worker_entry_opts(opts, _tag, _attrs, _namespace, _element), do: opts

  defp expanded_url({_src, url}), do: url
  defp expanded_url({_tag, _link, _src, url}), do: url

  defp handler_opts(opts, role, goal, tag, fetch_kind) do
    carried = if role == "script" or tag == "script", do: script_context(opts), else: %{}

    opts
    |> drop_script_context()
    |> Map.put(:html_tag, role)
    |> Map.put(:reference_tag, tag)
    |> put_opt(:javascript_goal, goal)
    |> put_opt(:fetch_kind, fetch_kind)
    |> put_opt(:document_base, rules_document_base(fetch_kind, opts))
    |> Map.merge(carried)
  end

  defp rules_document_base(:speculation_rules, opts) do
    opts[:document_base] || opts[:referrer_url] || opts[:url]
  end

  defp rules_document_base(_fetch_kind, _opts), do: nil

  defp ref_result(%{url: url} = ref, opts, handler) when is_binary(url) do
    handler.(ref_element(ref), ref_opts(opts, ref))
  end

  defp ref_result(_ref, _opts, _handler), do: nil

  defp ref_element(%{spec: spec, url: url}) when spec == url, do: {"href", url}
  defp ref_element(%{spec: spec, url: url}), do: {"link", spec, "href", url}

  defp ref_opts(opts, ref) do
    opts
    |> drop_script_context()
    |> Map.put(:html_tag, ref.html_tag)
    |> Map.put(:reference_tag, ref.reference_tag)
    |> put_opt(:javascript_goal, ref.goal)
    |> put_opt(:import_map, ref.import_map)
    |> put_opt(:document_base, ref.document_base)
    |> put_opt(:worker_base, ref.worker_base)
    |> put_opt(:fetch_kind, ref[:fetch_kind])
    |> put_opt(:json_span, ref[:json_span])
  end

  defp script_context(opts) do
    %{}
    |> put_opt(:import_map, opts[:import_map])
    |> put_opt(:document_base, opts[:document_base])
  end

  defp drop_script_context(opts) do
    Map.drop(opts, [
      :javascript_goal,
      :cookie_navigation,
      :import_map,
      :document_base,
      :worker_base,
      :link_html_tag,
      :fetch_kind,
      :json_span
    ])
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Map.put(opts, key, value)

  defp raw_text(children) do
    Enum.map_join(children, fn
      text when is_binary(text) -> text
      {_tag, _attrs, inner} -> raw_text(inner)
      _ -> ""
    end)
  end

  defp attr_name(name) when name in ["style", "style_text"], do: "href"
  defp attr_name(name), do: name

  defp raw_link({_src, link}), do: link
  defp raw_link({_tag, link, _src, _url}), do: link
end
