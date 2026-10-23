defmodule Crawler.Analysis.Interpretation do
  @moduledoc false

  alias Crawler.Analysis.Budget
  alias Crawler.Analysis.CSS
  alias Crawler.Analysis.Limits
  alias Crawler.Analysis.Occurrence
  alias Crawler.HTMLReferences
  alias Crawler.HTMLSpans
  alias Crawler.ImportMap
  alias Crawler.Parser.ScriptReferences
  alias Crawler.Parser.SourceMap
  alias Crawler.Parser.SpeculationRules
  alias Crawler.Parser.WebManifest
  alias Crawler.Robots
  alias Crawler.URL
  alias Crawler.XMLSpans

  @context_keys ~w(html_tag reference_tag javascript_goal credentials page_open fetch_kind
    document_base document_url import_map worker_base style_group css_revision css_base url referrer_url)a

  def context_key(context) do
    context
    |> Map.take(@context_keys)
    |> Enum.reject(fn {_key, value} -> value == nil end)
    |> Map.new()
  end

  def run(analysis, context, budget) do
    state = %{analysis: analysis, occurrences: [], count: 0, budget: budget}
    context = Map.new(context)
    context = Map.put(context, :managed_css_snapshot, Map.has_key?(context, :css_tokens))

    with {:ok, budget} <-
           Crawler.Analysis.adopt(
             budget,
             Map.take(context, [:css_tokens, :css_references, :import_map])
           ),
         :ok <- validate_snapshot(context, analysis),
         {:ok, budget} <- snapshot_facts(context, budget),
         {:ok, state} <- interpret(analysis.root, context, %{state | budget: budget}) do
      {:ok, Enum.reverse(state.occurrences), state.budget}
    end
  end

  defp interpret(id, opts, state) do
    region = state.analysis.regions[id]

    case region.kind do
      kind when kind in [:html, :xml] ->
        document(region, opts, state)

      {:javascript, goal} ->
        javascript(region, goal, opts, state)

      :css ->
        if region.parent == nil do
          opts = root_css_options(opts)
          base = opts[:referrer_url] || opts[:url]

          with {:ok, sheets, budget} <-
                 CSS.sheets_result(state.analysis, [id], %{id => base}, state.budget),
               {:ok, snapshot, budget} <-
                 CSS.snapshot_result(state.analysis, sheets, opts, budget) do
            css(region, with_snapshot(opts, snapshot), %{state | budget: budget})
          end
        else
          css(region, opts, state)
        end

      :json ->
        case opts[:fetch_kind] do
          :manifest -> manifest(region, opts, state)
          :speculation_rules -> rules(region, opts, state)
          :source_map -> source_map(region, opts, state)
          _kind -> {:error, :invalid_json_role}
        end

      :speculation_rules ->
        rules(region, opts, state)

      :source_map ->
        source_map(region, opts, state)

      :import_map ->
        {:ok, state}

      :attribute ->
        attribute(region, opts, state)
    end
  end

  def css_groups(analysis, opts, budget) do
    with {:ok, state} <-
           collect_css_groups(analysis.root, opts, analysis, %{groups: [], budget: budget}) do
      {:ok, Enum.reverse(state.groups), state.budget}
    end
  end

  defp collect_css_groups(id, opts, analysis, state) do
    region = analysis.regions[id]

    case region.kind do
      kind when kind in [:html, :xml] ->
        with {:ok, prepared, budget} <- prepare_document(region, opts, analysis, state.budget),
             {:ok, state} <-
               add_css_group(prepared.sheets, prepared.options, analysis, %{
                 state
                 | budget: budget
               }) do
          Enum.reduce_while(prepared.entries, {:ok, state}, fn entry, {:ok, state} ->
            collect_entry_css_groups(entry, prepared.options, analysis, state)
          end)
        end

      :css ->
        opts = root_css_options(opts)
        base = opts[:referrer_url] || opts[:url]

        with {:ok, sheets, budget} <-
               CSS.sheets_result(analysis, [id], %{id => base}, state.budget),
             do: add_css_group(sheets, opts, analysis, %{state | budget: budget})

      _kind ->
        {:ok, state}
    end
  end

  defp collect_entry_css_groups(entry, opts, analysis, state) do
    current = entry_options(opts, entry)

    Enum.reduce_while(entry.children, {:ok, state}, fn child, {:ok, state} ->
      collect_child_css_groups(child, current, analysis, state)
    end)
    |> case do
      {:ok, state} -> {:cont, {:ok, state}}
      error -> {:halt, error}
    end
  end

  defp collect_child_css_groups(child, opts, analysis, state) do
    nested = analysis.regions[child]

    if nested.metadata[:name] == "srcdoc" do
      case collect_css_groups(child, srcdoc_options(opts, nested), analysis, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    else
      {:cont, {:ok, state}}
    end
  end

  defp add_css_group([], _opts, _analysis, state), do: {:ok, state}

  defp add_css_group(sheets, opts, analysis, state) do
    with {:ok, budget} <- Budget.charge(state.budget, Budget.cost(:context)) do
      group = %{
        style_group: opts[:style_group],
        source_revision: analysis.revision,
        sheets: sheets
      }

      {:ok, %{state | groups: [group | state.groups], budget: budget}}
    end
  end

  defp prepare_document(region, opts, analysis, budget) do
    hold = Enum.reduce(region.facts.tags, 0, &max(Crawler.Analysis.policy_scratch(&1), &2))

    with {:ok, budget} <- Budget.reserve(budget, hold),
         {:ok, prepared, budget} <- prepare_document_reserved(region, opts, analysis, budget),
         {:ok, budget} <- Budget.release(budget, hold),
         do: {:ok, prepared, budget}
  end

  defp prepare_document_reserved(region, opts, analysis, budget) do
    base = opts[:referrer_url] || opts[:document_base] || opts[:url] || ""
    location = opts[:document_url] || opts[:referrer_url] || opts[:url]

    with {:ok, base, budget} <- html_document_base(region, opts, base, budget),
         {:ok, tags, budget} <-
           if(region.kind == :xml,
             do: XMLSpans.resolve_bases_result(region.facts.tags, base, budget),
             else: {:ok, region.facts.tags, budget}
           ),
         {:ok, budget} <-
           Budget.charge(
             budget,
             Budget.cost(:token, length(tags)) + Budget.cost(:context) +
               Budget.cost(:list_cell, length(region.children) * 5)
           ) do
      opts =
        opts
        |> Map.put(:document_base, base)
        |> Map.put(:document_url, location)
        |> Map.put(:referrer_url, base)
        |> Map.put_new(:style_group, location)

      by_tag = Enum.group_by(region.children, fn id -> analysis.regions[id].metadata.tag.span end)

      entries =
        tags
        |> Enum.reject(&(&1.closing? or &1.in_template?))
        |> Enum.map(fn tag ->
          base = if region.kind == :xml, do: tag.effective_base, else: base
          %{tag: tag, children: Map.get(by_tag, tag.span, []), base: base}
        end)

      ids = Enum.flat_map(entries, & &1.children)

      bases =
        Enum.reduce(entries, %{}, fn entry, bases ->
          Enum.reduce(entry.children, bases, &Map.put(&2, &1, entry.base))
        end)

      with {:ok, sheets, budget} <-
             CSS.sheets_result(analysis, ids, bases, budget, &css_region_enabled?(&1, opts)),
           do: {:ok, %{options: opts, tags: tags, entries: entries, sheets: sheets}, budget}
    end
  end

  defp html_document_base(region, opts, base, budget) do
    tag =
      if region.kind == :html or Crawler.MediaType.xhtml?(opts[:content_type]) do
        Enum.find(region.facts.tags, fn tag ->
          tag.name == "base" and not tag.closing? and tag.namespace == :html and
            not tag.in_template? and not tag.in_shadow_root? and
            HTMLSpans.active_attribute(tag, "href", region.kind) != nil
        end)
      end

    if tag,
      do:
        resolve_base(HTMLSpans.active_attribute(tag, "href", region.kind).decoded, base, budget),
      else: {:ok, base, budget}
  end

  defp entry_options(opts, entry),
    do: opts |> Map.put(:referrer_url, entry.base) |> Map.put(:document_base, entry.base)

  defp root_css_options(opts) do
    Map.put_new(opts, :style_group, opts[:document_url] || opts[:referrer_url] || opts[:url])
  end

  defp srcdoc_options(opts, region) do
    opts
    |> Map.drop([
      :headers,
      :javascript_goal,
      :import_map,
      :worker_base,
      :fetch_kind,
      :credentials,
      :style_group,
      :robots_nofollow,
      :document_base,
      :page_open,
      :json_span,
      :document_styles,
      :document_style_id
    ])
    |> Map.put(:srcdoc, true)
    |> Map.put(:content_type, "text/html")
    |> Map.put(:html_tag, "a")
    |> Map.put(
      :style_group,
      {:srcdoc, opts[:document_url], opts[:document_base], :crypto.hash(:sha256, region.source)}
    )
  end

  defp document(region, opts, state) do
    with {:ok, prepared, budget} <- prepare_document(region, opts, state.analysis, state.budget),
         {:ok, opts, budget} <- robots_options(region, prepared.tags, prepared.options, budget),
         {:ok, opts, budget} <- document_css(prepared.sheets, opts, state.analysis, budget),
         {:ok, state} <- instructions(region, opts, %{state | budget: budget}) do
      initial = %{opts: Map.put(opts, :import_map, ImportMap.empty()), manifest: false}

      Enum.reduce_while(prepared.entries, {:ok, state, initial}, fn entry, {:ok, state, walk} ->
        current = entry_options(walk.opts, entry)

        with {:ok, candidate, budget} <- manifest_result(entry.tag, region.kind, state.budget) do
          ids = if candidate and walk.manifest, do: [], else: entry.children

          case document_children(ids, current, %{state | budget: budget}) do
            {:ok, state, current} ->
              walk = %{
                walk
                | opts: Map.put(walk.opts, :import_map, current[:import_map]),
                  manifest: walk.manifest or candidate
              }

              {:cont, {:ok, state, walk}}

            error ->
              {:halt, error}
          end
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, state, _walk} -> {:ok, state}
        error -> error
      end
    end
  end

  defp robots_options(region, tags, opts, budget) do
    cond do
      opts[:respect_robots] == false ->
        {:ok, Map.put(opts, :robots_nofollow, false), budget}

      opts[:robots_nofollow] == true ->
        {:ok, Map.put(opts, :robots_nofollow, true), budget}

      true ->
        with {:ok, budget} <- Budget.charge(budget, Budget.cost(:list_cell, length(tags))) do
          meta =
            if region.kind == :html or Crawler.MediaType.xhtml?(opts[:content_type]),
              do: Enum.filter(tags, &(&1.namespace == :html)),
              else: []

          with {:ok, nofollow, budget} <- Robots.nofollow_result(meta, opts, budget),
               do: {:ok, Map.put(opts, :robots_nofollow, nofollow), budget}
        end
    end
  end

  defp document_css(sheets, opts, analysis, budget) do
    if HTMLReferences.enabled?(opts, "css") do
      with {:ok, snapshot, budget} <- CSS.snapshot_result(analysis, sheets, opts, budget),
           do: {:ok, with_snapshot(opts, snapshot), budget}
    else
      {:ok, opts, budget}
    end
  end

  defp with_snapshot(opts, snapshot) do
    opts
    |> Map.put(:css_tokens, snapshot.tokens)
    |> Map.put(:css_references, snapshot.references)
    |> Map.put(:css_revision, snapshot.revision)
  end

  defp document_children(ids, opts, state) do
    Enum.reduce_while(ids, {:ok, state, opts}, fn id, {:ok, state, opts} ->
      region = state.analysis.regions[id]

      cond do
        region.kind == :import_map ->
          import_map_child(region, opts, state)

        region.metadata[:name] == "srcdoc" ->
          continue(interpret(id, srcdoc_options(opts, region), state), opts)

        true ->
          continue(interpret(id, opts, state), opts)
      end
    end)
  end

  defp import_map_child(region, opts, state) do
    tag = region.metadata.tag

    result =
      if HTMLReferences.enabled?(opts, "js") and not tag.in_shadow_root? do
        case ImportMap.from_located_result(
               region.facts,
               opts[:document_base] || "",
               state.budget
             ) do
          {:error, :invalid_import_map, budget} -> {:ok, opts[:import_map], budget}
          {:error, reason, _budget} -> {:error, reason}
          {:ok, parsed, budget} -> ImportMap.merge_result(parsed, opts[:import_map], budget)
          error -> error
        end
      else
        {:ok, opts[:import_map], state.budget}
      end

    case result do
      {:ok, map, budget} ->
        {:cont, {:ok, %{state | budget: budget}, Map.put(opts, :import_map, map)}}

      error ->
        {:halt, error}
    end
  end

  defp continue({:ok, state}, opts), do: {:cont, {:ok, state, opts}}
  defp continue(error, _opts), do: {:halt, error}

  defp resolve_base(raw, base, budget) do
    case URL.resolve_result(raw, base, budget) do
      {:ok, url, budget} ->
        hold = 512 * (byte_size(raw) + byte_size(url) + 1)

        with {:ok, budget} <- Budget.reserve(budget, hold) do
          result =
            if String.ends_with?(URI.parse(URL.sanitize(raw)).path || "", "/"),
              do: keep_directory(url),
              else: url

          with {:ok, budget} <-
                 Budget.settle(budget, hold, byte_size(result) + Budget.cost(:binary)),
               do: {:ok, result, budget}
        end

      {:skip, budget} ->
        {:ok, base, budget}

      error ->
        error
    end
  end

  defp keep_directory(url) do
    uri = URI.parse(url)
    path = uri.path || ""
    if String.ends_with?(path, "/"), do: url, else: URI.to_string(%{uri | path: path <> "/"})
  end

  defp manifest_result(%{name: "link", namespace: :html} = tag, kind, budget) do
    hold = Crawler.Analysis.policy_scratch(tag)

    with {:ok, budget} <- Budget.reserve(budget, hold) do
      attrs = tag |> HTMLSpans.active_attributes(kind) |> Enum.map(&{&1.name, &1.decoded})
      manifest = match?(%{fetch_kind: :manifest}, HTMLReferences.link_choice(attrs))
      with {:ok, budget} <- Budget.release(budget, hold), do: {:ok, manifest, budget}
    end
  end

  defp manifest_result(_tag, _kind, budget), do: {:ok, false, budget}

  defp attribute(region, opts, state) do
    hold = Crawler.Analysis.policy_scratch(region.metadata.tag)

    with {:ok, budget} <- Budget.reserve(state.budget, hold),
         {:ok, state} <- attribute_reserved(region, opts, %{state | budget: budget}),
         {:ok, budget} <- Budget.release(state.budget, hold),
         do: {:ok, %{state | budget: budget}}
  end

  defp attribute_reserved(region, opts, state) do
    tag = region.metadata.tag
    attrs = tag.active_attributes
    name = region.metadata.name

    if name in eligible_attributes(tag, attrs, opts) do
      {role, reference_tag, fetch_kind} = reference_identity(tag, name, attrs)
      goal = reference_goal(tag, name, attrs, role, fetch_kind)
      credentials = HTMLReferences.credentials(tag.name, name, attrs, tag.namespace)
      context = child_context(opts, role, reference_tag, goal, fetch_kind, credentials)

      context =
        if role == "a",
          do: Map.put(context, :page_open, page_open?(tag, attrs)),
          else: Map.put(context, :page_open, false)

      context =
        if HTMLReferences.worker_entry?(attrs) and tag.name == "link",
          do: Map.put(context, :worker_base, :resolved),
          else: context

      context =
        if stylesheet?(tag, attrs),
          do: carry(context, :style_group, opts[:style_group]),
          else: context

      Enum.reduce_while(region.facts, {:ok, state}, fn fact, {:ok, state} ->
        attribute_fact(region, tag, attrs, name, fact, context, opts, state)
      end)
    else
      {:ok, state}
    end
  end

  defp attribute_fact(region, tag, attrs, name, {_at, _len, value} = fact, context, opts, state) do
    if same_drawing?(tag, name, value) do
      {:cont, {:ok, state}}
    else
      attribute_reference(region, tag, attrs, name, fact, context, opts, state)
    end
  end

  defp attribute_reference(region, tag, attrs, name, {at, len, value}, context, opts, state) do
    case resolved(value, opts, state.budget) do
      {:skip, budget} ->
        {:cont, {:ok, %{state | budget: budget}}}

      {:ok, url, budget} ->
        context =
          if context[:worker_base] == :resolved,
            do: Map.put(context, :worker_base, url),
            else: context

        span = if tag[:header?], do: nil, else: {at, len}

        emit_occurrence(
          region,
          span,
          value,
          url,
          context,
          :plain,
          name,
          opts,
          %{state | budget: budget},
          %{integrity: integrity(tag, attrs, region.parent)}
        )
        |> reduce_result()

      error ->
        {:halt, error}
    end
  end

  defp eligible_attributes(tag, attrs, opts),
    do: HTMLReferences.attributes(policy_name(tag), attrs, opts, tag.namespace)

  defp policy_name(%{namespace_uri: _uri, namespace: :svg, name: name}) do
    case name do
      "feImage" -> "feimage"
      "linearGradient" -> "lineargradient"
      "radialGradient" -> "radialgradient"
      invalid when invalid in ["feimage", "lineargradient", "radialgradient"] -> "unknown"
      other -> other
    end
  end

  defp policy_name(tag), do: tag.name

  defp same_drawing?(%{namespace: :svg} = tag, name, value) do
    HTMLReferences.local_reference?(value) and
      (name == "style" or HTMLReferences.presentation_attribute?(name) or
         HTMLReferences.role(policy_name(tag), name, []) == "img")
  end

  defp same_drawing?(_tag, _name, _value), do: false

  defp reference_identity(%{namespace: :math}, name, _attrs) when name in ["href", "xlink:href"],
    do: {"a", "a", nil}

  defp reference_identity(%{name: "link", namespace: :html}, "href", attrs) do
    case HTMLReferences.link_choice(attrs) do
      %{html_tag: role, reference_tag: tag, fetch_kind: kind} -> {role, tag, kind}
      :skip -> {"link", "link", nil}
    end
  end

  defp reference_identity(%{name: "script", namespace: :html}, "src", attrs) do
    if HTMLReferences.speculation_rules?(attrs),
      do: {"link", "link", :speculation_rules},
      else: {"script", "script", nil}
  end

  defp reference_identity(tag, name, attrs),
    do: {HTMLReferences.role(policy_name(tag), name, attrs), tag.name, nil}

  defp reference_goal(_tag, _name, _attrs, _role, kind) when kind != nil, do: nil

  defp reference_goal(%{name: "script"}, _name, attrs, _role, _kind),
    do: HTMLReferences.script_goal(attrs)

  defp reference_goal(%{name: "link"}, _name, attrs, "script", _kind),
    do: HTMLReferences.preload_goal(attrs)

  defp reference_goal(_tag, _name, _attrs, _role, _kind), do: nil

  defp page_open?(%{name: "link"}, attrs) do
    case HTMLReferences.link_choice(attrs) do
      %{page_open: false} -> false
      _choice -> true
    end
  end

  defp page_open?(_tag, _attrs), do: true

  defp stylesheet?(%{name: "link", namespace: :html}, attrs),
    do: match?(%{channel: {:style, "css"}}, HTMLReferences.link_choice(attrs))

  defp stylesheet?(_tag, _attrs), do: false

  defp integrity(tag, attrs, parent) do
    if HTMLReferences.integrity_resource?(tag.name, attrs) do
      for attr <- tag.attributes,
          attr.name == "integrity",
          Map.get(attr, :namespace_uri) == nil,
          do: {parent, attr.span}
    end
  end

  defp javascript(region, goal, opts, state) do
    cond do
      opts[:javascript_goal] not in [nil, goal] and region.parent == nil ->
        {:error, :incompatible_script_goal}

      region.parent != nil and not HTMLReferences.enabled?(opts, "js") ->
        {:ok, state}

      true ->
        with {:ok, budget} <-
               Budget.charge(
                 state.budget,
                 Budget.cost(:context) +
                   Budget.cost(
                     :map_entry,
                     length(region.facts.source_map_urls) + length(region.children)
                   )
               ),
             opts <- script_options(region, goal, opts) |> source_map_options(region, state),
             {:ok, note, budget} <-
               SourceMap.javascript_result(region.source, opts, region.facts.scan, budget),
             opts <- Map.put(opts, :source_map_note, note),
             {:ok, state} <-
               ScriptReferences.reduce(
                 region.source,
                 opts,
                 region.facts.scan,
                 budget,
                 state,
                 fn ref, state, budget ->
                   script_reference(region, ref, opts, state, budget)
                 end
               )
               |> projection_result(),
             do: interpret_data_map(region, note, opts, state)
    end
  end

  defp script_reference(region, ref, opts, state, budget) do
    if is_binary(ref.url) do
      span = if is_integer(ref[:at]), do: {ref.at, ref.len}

      with {:ok, state} <-
             emit_occurrence(
               region,
               span,
               ref.spec,
               ref.url,
               ref_context(ref),
               script_encoding(region, ref),
               "href",
               opts,
               %{state | budget: budget},
               %{metadata: Map.take(ref, [:map_note])}
             ),
           do: {:ok, state, state.budget}
    else
      {:ok, state, budget}
    end
  end

  defp source_map_options(opts, region, state) do
    regions =
      Map.new(region.facts.source_map_urls, &{&1, nil})
      |> Map.merge(
        Map.new(region.children, fn id -> {state.analysis.regions[id].metadata.data_url, id} end)
      )

    opts
    |> Map.put(:source_map_notes, region.facts.source_map_notes)
    |> Map.put(:source_map_regions, regions)
  end

  defp interpret_data_map(_region, nil, _opts, state), do: {:ok, state}

  defp interpret_data_map(_region, note, opts, state) do
    case Map.get(opts[:source_map_regions], note.url) do
      nil ->
        {:ok, state}

      id ->
        source_map(
          state.analysis.regions[id],
          opts |> Map.put(:url, note.base) |> Map.put(:referrer_url, note.base),
          state
        )
    end
  end

  defp script_options(%{parent: nil}, goal, opts), do: Map.put(opts, :javascript_goal, goal)

  defp script_options(region, goal, opts) do
    opts
    |> Map.put(:javascript_goal, goal)
    |> Map.put(:inline_source, true)
    |> Map.put(:link_html_tag, "script")
    |> Map.delete(:headers)
    |> Map.put(
      :credentials,
      HTMLReferences.script_credentials(region.metadata.tag.active_attributes)
    )
  end

  defp script_encoding(_region, %{map_note: note}), do: {:source_map, :javascript, note}

  defp script_encoding(region, ref) do
    quote = if ref.at > 0, do: binary_part(region.source, ref.at - 1, 1), else: "\""
    {:javascript, quote}
  end

  defp ref_context(ref) do
    ref
    |> Map.take([
      :html_tag,
      :reference_tag,
      :import_map,
      :document_base,
      :document_url,
      :worker_base,
      :credentials,
      :fetch_kind,
      :page_open
    ])
    |> Map.put(:javascript_goal, ref.goal)
    |> Map.put_new(:credentials, :include)
    |> Map.put_new(:page_open, true)
  end

  defp css(region, opts, state) do
    hold =
      if region.metadata[:tag], do: Crawler.Analysis.policy_scratch(region.metadata.tag), else: 0

    with {:ok, budget} <- Budget.reserve(state.budget, hold),
         {:ok, state} <- css_reserved(region, opts, %{state | budget: budget}),
         {:ok, budget} <- Budget.release(state.budget, hold),
         do: {:ok, %{state | budget: budget}}
  end

  defp css_reserved(region, opts, state) do
    if css_region_enabled?(region, opts) do
      own = region.facts.resources
      extra = List.wrap(get_in(opts, [:css_tokens, region.id]))

      with :ok <-
             Limits.check(
               length(own) + length(extra),
               state.analysis.limits.max_facts,
               :css_tokens
             ),
           {:ok, budget} <-
             Budget.charge(
               state.budget,
               Budget.cost(:map_entry, length(own) + length(extra)) +
                 Budget.cost(:list_cell, 3 * length(own) + 2 * length(extra))
             ) do
        tokens = Enum.uniq_by(own ++ extra, &{&1.start, &1.length})

        result =
          Enum.reduce_while(tokens, {:ok, %{state | budget: budget}}, fn token, {:ok, state} ->
            css_token(region, token, opts, state)
          end)

        with {:ok, state} <- result,
             {:ok, state} <- css_extra_references(region, opts, state),
             do: css_source_map(region, opts, state)
      end
    else
      {:ok, state}
    end
  end

  defp css_token(region, token, opts, state) do
    if is_map(token) and is_binary(token[:value]) and is_integer(token[:start]) and
         is_integer(token[:length]) do
      if HTMLReferences.local_reference?(token.value) do
        {:cont, {:ok, state}}
      else
        css_token_reference(region, token, opts, state)
      end
    else
      {:halt, {:error, :invalid_css_token}}
    end
  end

  defp css_token_reference(region, token, opts, state) do
    case resolved(token.value, opts, state.budget) do
      {:skip, budget} ->
        {:cont, {:ok, %{state | budget: budget}}}

      {:ok, url, budget} ->
        kind = Map.get(token, :kind, :url)

        context =
          child_context(
            opts,
            "link",
            css_reference_tag(region),
            nil,
            nil,
            css_credentials(kind, opts)
          )
          |> carry(:css_revision, opts[:css_revision])

        context =
          if kind == :import,
            do: carry(context, :style_group, opts[:style_group]),
            else: context

        emit_occurrence(
          region,
          {token.start, token.length},
          token.value,
          url,
          Map.put(context, :page_open, false),
          {:css, Map.get(token, :quote, ""), Map.get(token, :closed?, true)},
          "href",
          opts,
          %{state | budget: budget}
        )
        |> reduce_result()

      error ->
        {:halt, error}
    end
  end

  defp css_extra_references(region, opts, state) do
    references = get_in(opts, [:css_references, region.id]) || []

    Enum.reduce_while(references, {:ok, state}, fn picture, {:ok, state} ->
      hold = byte_size(picture.token.value) + Budget.cost(:binary)

      with {:ok, budget} <- Budget.reserve(state.budget, hold) do
        local? = HTMLReferences.local_reference?(picture.token.value)

        with {:ok, budget} <- Budget.release(budget, hold) do
          if local?,
            do: {:cont, {:ok, %{state | budget: budget}}},
            else: css_extra_reference(region, picture, opts, %{state | budget: budget})
        else
          error -> {:halt, error}
        end
      else
        error -> {:halt, error}
      end
    end)
  end

  defp css_extra_reference(region, picture, opts, state) do
    current = Map.put(opts, :referrer_url, picture.base_url)

    case resolved(picture.token.value, current, state.budget) do
      {:skip, budget} ->
        {:cont, {:ok, %{state | budget: budget}}}

      {:ok, url, budget} ->
        context =
          child_context(opts, "link", css_reference_tag(region), nil, nil, :include)
          |> carry(:css_revision, opts[:css_revision])
          |> Map.put(:css_base, picture.base_url)

        emit_occurrence(
          region,
          nil,
          picture.token.value,
          url,
          context,
          :plain,
          "href",
          current,
          %{state | budget: budget},
          %{metadata: %{css_picture: picture}}
        )
        |> reduce_result()

      error ->
        {:halt, error}
    end
  end

  defp css_reference_tag(%{metadata: %{tag: tag}}), do: tag.name
  defp css_reference_tag(_region), do: "link"

  defp css_region_enabled?(region, opts) do
    (region.parent == nil or HTMLReferences.enabled?(opts, "css")) and
      css_attribute_enabled?(region, opts)
  end

  defp css_attribute_enabled?(%{metadata: %{name: name, tag: tag}}, opts),
    do: name in eligible_attributes(tag, tag.active_attributes, opts)

  defp css_attribute_enabled?(_region, _opts), do: true
  defp css_credentials(:font, _opts), do: :same_origin
  defp css_credentials(:import, opts), do: opts[:credentials] || :include
  defp css_credentials(_kind, _opts), do: :include

  defp css_source_map(%{metadata: %{name: _name}}, _opts, state), do: {:ok, state}

  defp css_source_map(region, opts, state) do
    opts =
      if region.parent != nil,
        do: opts |> Map.put(:inline_source, true) |> Map.delete(:headers),
        else: opts

    with {:ok, budget} <-
           Budget.charge(
             state.budget,
             Budget.cost(:context) +
               Budget.cost(
                 :map_entry,
                 length(region.facts.source_map_urls) + length(region.children)
               )
           ),
         opts <- source_map_options(opts, region, state),
         {:ok, note, budget} <- SourceMap.css_result(region.source, opts, region.facts, budget) do
      state = %{state | budget: budget}

      if note do
        with {:ok, ref, budget} <-
               SourceMap.annotation_ref_result(note, region.source, state.budget) do
          state = %{state | budget: budget}

          if is_binary(ref.url) do
            emit_occurrence(
              region,
              {ref.at, ref.len},
              ref.spec,
              ref.url,
              ref_context(ref),
              {:source_map, :css, note},
              "href",
              opts,
              state
            )
          else
            interpret_data_map(region, note, opts, state)
          end
        end
      else
        {:ok, state}
      end
    end
  end

  defp manifest(region, opts, state) do
    WebManifest.reduce_located(
      region.facts,
      opts[:referrer_url] || opts[:url] || "",
      state.budget,
      state,
      fn reference, state, budget ->
        manifest_reference(region, reference, opts, state, budget)
      end,
      HTMLReferences.enabled?(opts, "images")
    )
    |> projection_result()
  end

  defp manifest_reference(region, {kind, raw, url, at, len}, opts, state, budget) do
    if kind == :page or HTMLReferences.enabled?(opts, "images") do
      role = if kind == :page, do: "a", else: "img"
      context = child_context(opts, role, role, nil, nil, :include)
      metadata = if kind == :page and region.parent == nil, do: %{depth_delta: -1}, else: %{}

      with {:ok, state} <-
             emit_occurrence(
               region,
               {at, len},
               raw,
               url,
               context,
               :json,
               "href",
               opts,
               %{state | budget: budget},
               %{metadata: metadata}
             ),
           do: {:ok, state, state.budget}
    else
      {:ok, state, budget}
    end
  end

  defp rules(region, opts, state) do
    opts =
      if region.parent == nil,
        do: Map.put(opts, :fetch_kind, :speculation_rules),
        else: Map.delete(opts, :fetch_kind)

    SpeculationRules.reduce_located(region.facts, opts, state.budget, state, fn {raw, url, at,
                                                                                 len, action},
                                                                                state,
                                                                                budget ->
      credentials = if action == :prefetch, do: :same_site, else: :include

      context =
        child_context(opts, "a", "a", nil, nil, credentials)
        |> Map.put(:page_open, action != :prefetch)

      metadata = if region.parent == nil, do: %{depth_delta: -1}, else: %{}

      with {:ok, state} <-
             emit_occurrence(
               region,
               {at, len},
               raw,
               url,
               context,
               :json,
               "href",
               opts,
               %{state | budget: budget},
               %{metadata: metadata}
             ),
           do: {:ok, state, state.budget}
    end)
    |> projection_result()
  end

  defp source_map(region, opts, state) do
    SourceMap.reduce_located(region.facts, opts, state.budget, state, fn entry, state, budget ->
      context = child_context(opts, "link", "link", nil, entry.fetch_kind, :include)

      with {:ok, state} <-
             emit_occurrence(
               region,
               entry.json_span,
               entry.raw,
               entry.url,
               context,
               :json,
               "href",
               opts,
               %{state | budget: budget}
             ),
           do: {:ok, state, state.budget}
    end)
    |> projection_result()
  end

  defp instructions(%{kind: :xml} = region, opts, state) do
    if HTMLReferences.enabled?(opts, "css") do
      Enum.reduce_while(region.facts.instructions, {:ok, state}, fn instruction, {:ok, state} ->
        stylesheet_instruction(region, instruction, opts, state)
      end)
    else
      {:ok, state}
    end
  end

  defp instructions(_region, _opts, state), do: {:ok, state}

  defp stylesheet_instruction(region, instruction, opts, state) do
    attrs = Enum.map(instruction.attributes, &{&1.name, &1.decoded})
    href = Enum.find(instruction.attributes, &(&1.name == "href"))

    if href != nil and Crawler.MediaType.css?(HTMLReferences.attribute(attrs, "type")) and
         not instruction.in_template? do
      case resolved(href.decoded, opts, state.budget) do
        {:skip, budget} ->
          {:cont, {:ok, %{state | budget: budget}}}

        {:ok, url, budget} ->
          context =
            child_context(opts, "link", "link", nil, nil, :include)
            |> carry(:style_group, opts[:style_group])

          emit_occurrence(
            region,
            href.value_span,
            href.decoded,
            url,
            context,
            :xml_attribute,
            "href",
            opts,
            %{state | budget: budget}
          )
          |> reduce_result()

        error ->
          {:halt, error}
      end
    else
      {:cont, {:ok, state}}
    end
  end

  defp child_context(opts, role, tag, goal, kind, credentials) do
    context = %{
      html_tag: role,
      reference_tag: tag,
      javascript_goal: goal,
      fetch_kind: kind,
      credentials: credentials
    }

    context =
      if role == "script" or tag == "script",
        do: Map.merge(context, Map.take(opts, [:import_map, :document_base, :document_url])),
        else: context

    if kind == :speculation_rules,
      do:
        Map.put(
          context,
          :document_base,
          opts[:document_base] || opts[:referrer_url] || opts[:url]
        ),
      else: context
  end

  defp carry(context, _key, nil), do: context
  defp carry(context, key, value), do: Map.put(context, key, value)

  defp resolved(value, opts, budget) do
    with {:ok, _hypothetical} <- Budget.count(budget, :occurrences),
         do:
           URL.resolve_result(
             value,
             opts[:referrer_url] || opts[:document_base] || opts[:url],
             budget
           )
  end

  defp snapshot_facts(context, budget) do
    count =
      Enum.reduce([:css_tokens, :css_references], 0, fn key, n ->
        Enum.reduce(Map.get(context, key, %{}), n, fn {_id, items}, n -> n + length(items) end)
      end)

    Budget.count(budget, :facts, count)
  end

  defp validate_snapshot(context, analysis) do
    tokens = Map.get(context, :css_tokens, %{})
    references = Map.get(context, :css_references, %{})

    valid? =
      is_map(tokens) and is_map(references) and
        Enum.all?(tokens, fn {id, items} ->
          case analysis.regions[id] do
            %{kind: :css, source: source} ->
              is_list(items) and Enum.all?(items, &valid_token?(&1, byte_size(source)))

            _other ->
              false
          end
        end) and
        Enum.all?(references, fn {id, items} ->
          match?(%{kind: :css}, analysis.regions[id]) and is_list(items) and
            Enum.all?(items, fn picture ->
              is_map(picture) and is_binary(picture[:base_url]) and
                valid_discovery_token?(picture[:token], analysis.limits.max_bytes)
            end)
        end)

    cond do
      not valid? ->
        {:error, :invalid_css_snapshot}

      map_size(tokens) + map_size(references) > 0 and context[:css_revision] == nil ->
        {:error, :missing_css_revision}

      true ->
        count = Enum.reduce(Map.values(tokens) ++ Map.values(references), 0, &(length(&1) + &2))
        Limits.check(count, analysis.limits.max_facts, :css_tokens)
    end
  end

  defp valid_discovery_token?(token, max_value_bytes) when is_map(token) do
    is_binary(token[:value]) and byte_size(token.value) <= max_value_bytes and
      String.valid?(token.value) and
      is_integer(token[:start]) and token.start >= 0 and is_integer(token[:length]) and
      token.length >= 0 and
      Map.get(token, :quote, "") in ["", "'", "\""]
  end

  defp valid_discovery_token?(_token, _max_value_bytes), do: false

  defp valid_token?(token, size) when is_map(token) do
    is_binary(token[:value]) and is_integer(token[:start]) and token.start >= 0 and
      is_integer(token[:length]) and token.length >= 0 and token.start + token.length <= size and
      Map.get(token, :quote, "") in ["", "'", "\""]
  end

  defp valid_token?(_token, _size), do: false

  defp fragment_result(value, budget) do
    case :binary.match(value, "#") do
      :nomatch ->
        {:ok, nil, budget}

      _match ->
        hold = 512 * (byte_size(value) + 1)

        with {:ok, budget} <- Budget.reserve(budget, hold) do
          [_base, fragment] = :binary.split(URL.sanitize(value), "#")
          fragment = Crawler.URL.Percent.encode(fragment, :fragment)

          with {:ok, budget} <-
                 Budget.settle(budget, hold, byte_size(fragment) + Budget.cost(:binary)),
               do: {:ok, fragment, budget}
        end
    end
  end

  defp occurrence(region, span, value, url, context, encoding, element, opts, fragment) do
    source_role = if region.kind == :json, do: opts[:fetch_kind], else: region.kind

    %Occurrence{
      id: {region.id, span, url, source_role, context_key(context)},
      region: region.id,
      source_role: source_role,
      span: span,
      value: value,
      url: url,
      fragment: fragment,
      context: context,
      encoding: encoding,
      element: element,
      namespace: get_in(region.metadata, [:tag, :namespace]),
      source_base: opts[:referrer_url] || opts[:document_base] || opts[:url],
      document_base: opts[:document_base],
      srcdoc: opts[:srcdoc] == true,
      robots_nofollow: opts[:robots_nofollow] == true
    }
  end

  defp emit_occurrence(
         region,
         span,
         value,
         url,
         context,
         encoding,
         element,
         opts,
         state,
         extras \\ %{}
       ) do
    with {:ok, budget} <-
           Budget.charge(state.budget, Budget.cost(:occurrence) + Budget.cost(:context),
             occurrences: 1
           ),
         {:ok, fragment, budget} <- fragment_result(value, budget) do
      occurrence =
        occurrence(region, span, value, url, context, encoding, element, opts, fragment)

      occurrence = struct(occurrence, extras)

      occurrence = %{
        occurrence
        | source_revision: state.analysis.revision,
          source_mode: state.analysis.mode,
          id: {state.analysis.revision, state.analysis.mode, occurrence.id}
      }

      {:ok,
       %{
         state
         | budget: budget,
           count: state.count + 1,
           occurrences: [occurrence | state.occurrences]
       }}
    end
  end

  defp reduce_result({:ok, state}), do: {:cont, {:ok, state}}
  defp reduce_result(error), do: {:halt, error}

  defp projection_result({:ok, state, budget}), do: {:ok, %{state | budget: budget}}
  defp projection_result(error), do: error
end
