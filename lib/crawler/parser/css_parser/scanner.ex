defmodule Crawler.Parser.CssParser.Scanner do
  @moduledoc false

  alias Crawler.Parser.CssParser.Identifier
  alias Crawler.Parser.CssParser.ImportRule
  alias Crawler.Parser.CssParser.Value

  require Identifier

  @image_properties MapSet.new(~w(
    background background-image
    border-image border-image-source
    mask mask-image
    list-style list-style-image
    cursor content
    fill stroke clip-path
    marker marker-start marker-mid marker-end
  ))

  def resources(body), do: body |> scan(:stylesheet) |> Map.fetch!(:resources) |> Enum.reverse()
  def comment_spans(body), do: body |> scan(:stylesheet) |> Map.fetch!(:comments)

  def analyze(body, opts \\ []) when is_binary(body) do
    state = scan(body, Keyword.get(opts, :mode, :stylesheet))

    %{
      resources: Enum.reverse(state.resources),
      comments: state.comments,
      bindings: Enum.reverse(state.bindings),
      uses: Enum.reverse(state.uses),
      registrations: Enum.reverse(state.registrations)
    }
  end

  defp scan(body, mode) do
    walk(body, 0, initial(mode))
  end

  defp initial(mode) do
    %{
      mode: mode,
      stack: [],
      resources: [],
      comments: [],
      depth: 0,
      font_depth: nil,
      font_src?: false,
      src_pending?: false,
      at_rule: nil,
      rule: nil,
      prelude: :ready,
      import_rule: nil,
      suppress_depth: nil,
      condition_depth: nil,
      decl_name: nil,
      value?: false,
      binding: nil,
      bindings: [],
      uses: [],
      property: nil,
      property_name: nil,
      registrations: [],
      rule_id: 0,
      next_rule: 0,
      rule_ids: []
    }
  end

  defp walk(body, offset, state) do
    {body, offset, comments} = Value.trivia(body, offset)
    step(body, offset, %{state | comments: comments ++ state.comments})
  end

  defp step(<<>>, _offset, state), do: state |> finish_import() |> commit_value()

  defp step(<<"@", body::binary>>, offset, state) do
    {word, tail} = Identifier.take(body)
    finish = offset + 1 + byte_size(body) - byte_size(tail)
    state = state |> drop_import() |> begin_at(String.downcase(word, :ascii))
    walk(tail, finish, %{state | src_pending?: false})
  end

  defp step(<<"{", tail::binary>>, offset, state) do
    walk(tail, offset + 1, open_block(state))
  end

  defp step(<<"}", tail::binary>>, offset, state) do
    walk(tail, offset + 1, close_block(state))
  end

  defp step(<<";", tail::binary>>, offset, state) do
    walk(tail, offset + 1, end_semicolon(state))
  end

  defp step(<<":", tail::binary>>, offset, state) do
    walk(tail, offset + 1, mark_src(state))
  end

  defp step(<<"#", body::binary>>, offset, state) do
    {_name, tail} = Identifier.take(body)
    finish = offset + 1 + byte_size(body) - byte_size(tail)
    state = hash_import(state)
    walk(tail, finish, finish_token(state, %{stack: consume_hash(state.stack)}))
  end

  defp step(<<")", tail::binary>>, offset, state) do
    walk(tail, offset + 1, finish_token(close_top(state), %{}))
  end

  defp step(<<",", tail::binary>>, offset, state) do
    state = state |> comma_var() |> comma_import()
    walk(tail, offset + 1, finish_token(state, %{stack: next_candidate(state.stack)}))
  end

  defp step(<<"(", tail::binary>>, offset, state) do
    state = open_import_paren(state)
    walk(tail, offset + 1, finish_token(state, %{stack: [:other | state.stack]}))
  end

  defp step(body, offset, state) do
    case Value.quote_info(body) do
      nil ->
        code(body, offset, state)

      _quote ->
        {token, tail, finish, valid?} = Value.quoted(body, offset)
        state = accept_quoted(state, token, valid?)
        walk(tail, finish, finish_token(state, %{stack: used_candidate(state.stack)}))
    end
  end

  defp code(<<byte, _rest::binary>> = body, offset, state)
       when Identifier.name_byte(byte) or byte == ?\\ do
    {word, tail} = Identifier.take(body)
    finish = offset + byte_size(body) - byte_size(tail)

    case tail do
      <<"(", inner::binary>> -> function(String.downcase(word, :ascii), inner, finish + 1, state)
      _other -> atom(body, tail, offset, finish, state)
    end
  end

  defp code(<<byte, tail::binary>>, offset, %{import_rule: rule} = state) when is_map(rule) do
    state = %{state | import_rule: ImportRule.symbol(rule, byte)}
    walk(tail, offset + 1, state)
  end

  defp code(body, offset, state) do
    <<_byte, tail::binary>> = body
    atom(body, tail, offset, offset + 1, state)
  end

  defp function("url", body, offset, state) do
    state = feed_url(state)
    {token, tail, finish, comments} = Value.url(body, offset)
    state = accept_url(state, token)

    walk(
      tail,
      finish,
      finish_token(state, %{
        stack: used_candidate(state.stack),
        comments: comments ++ state.comments
      })
    )
  end

  defp function("var", body, offset, state) do
    state = import_call(state, "var")
    state = %{state | stack: [{:var, :name, nil, empty_fallback()} | state.stack]}
    walk(body, offset, finish_token(state, %{}))
  end

  defp function(name, body, offset, state) do
    state = import_call(state, name)
    walk(body, offset, finish_token(%{state | stack: [function_frame(name) | state.stack]}, %{}))
  end

  defp function_frame(name) when name in ["image-set", "-webkit-image-set"],
    do: {:image_set, true}

  defp function_frame("image"), do: {:image, true}
  defp function_frame(_name), do: :other

  defp atom(body, tail, offset, finish, state) do
    state = note_word(state, ident_word(body, tail, offset, finish))

    if image_set_candidate?(state.stack) and is_nil(state.import_rule) do
      {token, bare_tail, bare_finish} = Value.bare(body, offset)
      state = if bare_url?(token.value), do: keep_resource(state, token), else: state
      walk(bare_tail, bare_finish, finish_ident(state, %{stack: used_candidate(state.stack)}))
    else
      walk(tail, finish, finish_ident(state))
    end
  end

  defp accept_url(state, nil) do
    if import?(state), do: feed_address(state, nil), else: state
  end

  defp accept_url(state, token) do
    cond do
      import?(state) -> feed_address(state, token)
      not keep_url?(state, token) -> state
      true -> keep_resource(state, token)
    end
  end

  defp accept_quoted(state, _token, false), do: state

  defp accept_quoted(state, token, true) do
    cond do
      import?(state) -> feed_address(state, token)
      candidate?(state.stack) -> keep_resource(capture_syntax(state, token), token)
      true -> capture_syntax(state, token)
    end
  end

  defp feed_address(state, token) do
    case ImportRule.address(state.import_rule, token) do
      {:picture, rule} -> keep_picture(%{state | import_rule: rule}, token)
      {:keep, rule} -> %{state | import_rule: rule}
    end
  end

  defp keep_picture(state, token) do
    if keep_url?(state, token), do: keep_resource(state, token), else: state
  end

  defp keep_resource(state, token) do
    case capture_kind(state) do
      :drop ->
        state

      :binding ->
        put_binding_url(state, token)

      :initial ->
        put_initial(state, token)

      :var ->
        put_var_url(state, token)

      :resource ->
        %{state | resources: [Map.put(token, :kind, resource_kind(state)) | state.resources]}
    end
  end

  defp capture_kind(state) do
    cond do
      suppressed?(state) -> :drop
      condition?(state) -> :drop
      fallback_context?(state) -> :var
      var_frame?(state) -> :var
      is_map(state.binding) -> :binding
      initial?(state) -> :initial
      true -> :resource
    end
  end

  defp put_binding_url(state, token) do
    urls = [Map.put(token, :kind, :url) | state.binding.urls]
    %{state | binding: %{state.binding | urls: urls}}
  end

  defp put_initial(state, token) do
    %{state | property: %{state.property | initial: Map.put(token, :kind, :url)}}
  end

  defp put_var_url(state, token) do
    token = Map.put(token, :kind, :url)
    %{state | stack: add_fallback_url(state.stack, token)}
  end

  defp add_fallback_url([{:var, :fallback, name, fallback} | tail], token) do
    fallback = %{fallback | urls: fallback.urls ++ [token]}
    [{:var, :fallback, name, fallback} | tail]
  end

  defp add_fallback_url([frame | tail], token), do: [frame | add_fallback_url(tail, token)]
  defp add_fallback_url([], _token), do: []

  defp resource_kind(%{font_src?: true}), do: :font
  defp resource_kind(_state), do: :url

  defp keep_url?(%{at_rule: :namespace}, _token), do: false
  defp keep_url?(_state, %{value: value}), do: not local_fragment?(value)

  defp local_fragment?(value) do
    value |> String.trim() |> String.starts_with?("#")
  end

  defp begin_at(state, "import"), do: begin_import(state)

  defp begin_at(state, "namespace") do
    %{state | at_rule: :namespace, rule: :namespace, prelude: close_prelude(state)}
  end

  defp begin_at(%{depth: 0, prelude: :imports} = state, "charset") do
    %{state | rule: :charset, prelude: :closed}
  end

  defp begin_at(state, "charset"), do: %{state | rule: :charset}
  defp begin_at(state, "layer"), do: %{state | rule: :layer}
  defp begin_at(state, "supports-condition"), do: %{state | rule: :supports_condition}

  defp begin_at(state, "font-face") do
    %{state | at_rule: :font_face, rule: :font_face}
  end

  defp begin_at(state, "property") do
    %{state | rule: :property, property_name: nil}
  end

  defp begin_at(state, name) when name in ["media", "supports", "container"] do
    %{state | rule: {:at, name}, condition_depth: state.depth}
  end

  defp begin_at(state, name), do: %{state | rule: {:at, name}}

  defp begin_import(%{mode: :declarations} = state) do
    %{state | rule: :import, import_rule: ImportRule.declaration()}
  end

  defp begin_import(state) do
    emit? = state.depth == 0 and state.prelude != :closed and not suppressed?(state)
    %{state | rule: :import, import_rule: ImportRule.new(emit?)}
  end

  defp close_prelude(%{depth: 0}), do: :closed
  defp close_prelude(state), do: state.prelude

  defp drop_import(%{import_rule: nil} = state), do: state
  defp drop_import(state), do: %{state | import_rule: nil}

  defp finish_import(%{import_rule: nil} = state), do: state

  defp finish_import(state) do
    case ImportRule.finish(state.import_rule) do
      {:emit, token} ->
        prelude = if state.prelude == :closed, do: :closed, else: :imports

        %{
          state
          | import_rule: nil,
            prelude: prelude,
            resources: [Map.put(token, :kind, :import) | state.resources]
        }

      :drop ->
        %{state | import_rule: nil}
    end
  end

  defp open_block(state) do
    state = state |> prelude_block() |> open_rule()
    depth = state.depth + 1

    state = %{
      state
      | depth: depth,
        font_depth: opened_font_depth(state, depth),
        at_rule: nil,
        src_pending?: false,
        property: started_property(state, depth),
        rule: nil,
        value?: false,
        decl_name: nil
    }

    commit_value(state)
  end

  defp prelude_block(%{import_rule: rule} = state) when is_map(rule) do
    %{state | import_rule: nil, suppress_depth: state.depth + 1}
  end

  defp prelude_block(state) do
    state
    |> clear_condition()
    |> close_on_block()
  end

  defp clear_condition(%{condition_depth: depth, depth: depth} = state) when is_integer(depth) do
    %{state | condition_depth: nil}
  end

  defp clear_condition(state), do: state

  defp close_on_block(%{depth: 0, rule: :supports_condition} = state), do: state
  defp close_on_block(%{depth: 0, prelude: :closed} = state), do: state
  defp close_on_block(%{depth: 0} = state), do: %{state | prelude: :closed}
  defp close_on_block(state), do: state

  defp started_property(%{rule: :property, property_name: name}, depth) when is_binary(name) do
    %{name: name, depth: depth, syntax_url?: false, initial: nil}
  end

  defp started_property(state, _depth), do: state.property

  defp opened_font_depth(%{at_rule: :font_face, font_depth: nil}, depth), do: depth
  defp opened_font_depth(state, _depth), do: state.font_depth

  defp close_block(state) do
    state = state |> commit_value() |> close_property() |> close_rule()
    closed_font? = state.font_depth == state.depth
    depth = max(state.depth - 1, 0)

    %{
      state
      | depth: depth,
        font_depth: closed_font(state.font_depth, closed_font?),
        font_src?: state.font_src? and not closed_font?,
        src_pending?: false,
        at_rule: nil,
        value?: false,
        decl_name: nil,
        suppress_depth: next_suppress(state.suppress_depth, depth)
    }
  end

  defp close_property(%{property: %{depth: depth} = property, depth: depth} = state) do
    %{
      state
      | property: nil,
        property_name: nil,
        registrations: [registration(property) | state.registrations]
    }
  end

  defp close_property(state), do: state

  defp open_rule(%{mode: :declarations} = state), do: state

  defp open_rule(state) do
    next_rule = state.next_rule + 1

    %{
      state
      | rule_ids: [state.rule_id | state.rule_ids],
        rule_id: next_rule,
        next_rule: next_rule
    }
  end

  defp close_rule(%{mode: :declarations} = state), do: state

  defp close_rule(%{rule_ids: [rule_id | rule_ids]} = state) do
    %{state | rule_id: rule_id, rule_ids: rule_ids}
  end

  defp close_rule(state), do: state

  defp registration(property) do
    %{name: property.name, syntax_url?: property.syntax_url?, initial: property.initial}
  end

  defp closed_font(_depth, true), do: nil
  defp closed_font(depth, false), do: depth

  defp next_suppress(suppress, depth) when is_integer(suppress) and depth < suppress, do: nil
  defp next_suppress(suppress, _depth), do: suppress

  defp end_semicolon(state) do
    state =
      state
      |> finish_import()
      |> commit_value()
      |> close_statement()

    %{
      state
      | rule: nil,
        at_rule: nil,
        condition_depth: nil,
        font_src?: false,
        src_pending?: false,
        value?: false,
        decl_name: nil
    }
  end

  defp close_statement(%{depth: 0} = state), do: statement_prelude(state)
  defp close_statement(state), do: state
  defp statement_prelude(%{prelude: :closed} = state), do: state

  defp statement_prelude(%{rule: :layer, prelude: :imports} = state),
    do: %{state | prelude: :closed}

  defp statement_prelude(state), do: state

  defp commit_value(%{binding: nil} = state), do: state

  defp commit_value(state) do
    binding = %{state.binding | urls: Enum.reverse(state.binding.urls)}
    %{state | binding: nil, bindings: [binding | state.bindings]}
  end

  defp mark_src(state) do
    state = feed_symbol(state, ?:)

    state = %{
      state
      | font_src?: state.font_src? or src_descriptor?(state),
        src_pending?: false,
        at_rule: nil
    }

    if declaration_ready?(state), do: open_value(state), else: state
  end

  defp open_value(state) do
    state
    |> Map.put(:value?, true)
    |> Map.put(:binding, new_binding(state.decl_name, state.rule_id))
    |> reset_descriptor()
  end

  defp reset_descriptor(%{property: property} = state) when is_map(property) do
    property =
      case state.decl_name do
        "syntax" -> %{property | syntax_url?: false}
        "initial-value" -> %{property | initial: nil}
        _name -> property
      end

    %{state | property: property}
  end

  defp reset_descriptor(state), do: state

  defp new_binding("--" <> _ = name, rule_id) do
    %{name: name, urls: [], aliases: [], rule_id: rule_id}
  end

  defp new_binding(_name, _rule_id), do: nil

  defp src_descriptor?(state), do: state.src_pending? and font_face?(state)

  defp font_face?(%{font_depth: depth, depth: current}) when is_integer(depth),
    do: current >= depth

  defp font_face?(_state), do: false

  defp note_word(state, word) when is_binary(word) do
    state
    |> put_src(word)
    |> put_decl(word)
    |> put_property_name(word)
    |> feed_var_name(word)
    |> feed_import_ident(word)
  end

  defp note_word(state, _word), do: %{state | src_pending?: false}

  defp put_src(state, word) do
    %{state | src_pending?: String.downcase(word, :ascii) == "src" and font_face?(state)}
  end

  defp put_decl(state, "--" <> _ = word) do
    if declaration_ready?(state), do: %{state | decl_name: word}, else: state
  end

  defp put_decl(state, word) do
    if declaration_ready?(state),
      do: %{state | decl_name: String.downcase(word, :ascii)},
      else: state
  end

  defp put_property_name(%{rule: :property, depth: 0, property: nil} = state, "--" <> _ = word) do
    %{state | property_name: word}
  end

  defp put_property_name(state, _word), do: state

  defp declaration_ready?(state) do
    state.stack == [] and not state.value? and not import?(state) and declaration_context?(state) and
      not condition?(state) and not suppressed?(state)
  end

  defp declaration_context?(state), do: state.mode == :declarations or state.depth > 0

  defp feed_var_name(%{stack: [{:var, :name, _name, fallback} | tail]} = state, word) do
    %{state | stack: [{:var, :args, word, fallback} | tail]}
  end

  defp feed_var_name(state, _word), do: state

  defp feed_import_ident(%{import_rule: nil} = state, _word), do: state

  defp feed_import_ident(state, word) do
    %{state | import_rule: ImportRule.ident(state.import_rule, String.downcase(word, :ascii))}
  end

  defp ident_word(body, tail, offset, finish) do
    taken = finish - offset

    if taken > 0 and taken == byte_size(body) - byte_size(tail) do
      case Identifier.take(body) do
        {word, ^tail} when word != "" -> word
        _other -> nil
      end
    end
  end

  defp close_top(%{stack: [{:var, _stage, name, fallback} | tail]} = state) do
    state = commit_var(%{state | stack: tail}, name, fallback)
    close_import_paren(state)
  end

  defp close_top(state) do
    stack = state.stack |> Enum.drop(1) |> used_candidate()
    close_import_paren(%{state | stack: stack})
  end

  defp commit_var(state, name, fallback) do
    fallback = normalize_fallback(fallback)

    cond do
      not is_binary(name) ->
        state

      fallback_context?(state) ->
        attach_fallback_alias(state, name, fallback)

      is_map(state.binding) ->
        add_alias(state, name, fallback)

      use?(state) ->
        use = %{name: name, fallback: fallback, rule_id: state.rule_id}
        %{state | uses: [use | state.uses]}

      true ->
        state
    end
  end

  defp attach_fallback_alias(state, name, fallback) do
    %{state | stack: put_fallback_alias(state.stack, name, fallback)}
  end

  defp put_fallback_alias([{:var, :fallback, outer, acc} | tail], name, fallback) do
    nested = %{name: name, fallback: fallback}
    acc = %{acc | aliases: acc.aliases ++ [nested]}
    [{:var, :fallback, outer, acc} | tail]
  end

  defp put_fallback_alias([frame | tail], name, fallback) do
    [frame | put_fallback_alias(tail, name, fallback)]
  end

  defp put_fallback_alias([], _name, _fallback), do: []

  defp normalize_fallback(%{urls: [], aliases: []}), do: nil
  defp normalize_fallback(fallback), do: fallback
  defp empty_fallback, do: %{urls: [], aliases: []}

  defp add_alias(state, name, fallback) do
    entry = %{name: name, fallback: fallback}
    binding = %{state.binding | aliases: state.binding.aliases ++ [entry]}
    %{state | binding: binding}
  end

  defp use?(state) do
    state.value? and image_name?(state.decl_name) and not state.font_src? and
      is_nil(state.binding) and
      not suppressed?(state) and not condition?(state) and not import?(state) and
      not initial?(state)
  end

  defp image_name?(name) when is_binary(name), do: MapSet.member?(@image_properties, name)
  defp image_name?(_name), do: false

  defp comma_var(%{stack: [{:var, :args, name, fallback} | tail]} = state) do
    %{state | stack: [{:var, :fallback, name, fallback} | tail]}
  end

  defp comma_var(state), do: state

  defp comma_import(%{import_rule: nil} = state), do: state

  defp comma_import(state) do
    %{state | import_rule: ImportRule.comma(state.import_rule)}
  end

  defp open_import_paren(%{import_rule: nil} = state), do: state

  defp open_import_paren(state) do
    %{state | import_rule: ImportRule.paren(state.import_rule)}
  end

  defp close_import_paren(%{import_rule: nil} = state), do: state

  defp close_import_paren(state) do
    %{state | import_rule: ImportRule.close_paren(state.import_rule)}
  end

  defp import_call(%{import_rule: nil} = state, _name), do: state

  defp import_call(state, name) do
    %{state | import_rule: ImportRule.function(state.import_rule, name)}
  end

  # Value.url/2 consumes the closing parenthesis, so url() must not push paren depth.
  defp feed_url(%{import_rule: nil} = state), do: state

  defp feed_url(state) do
    %{state | import_rule: ImportRule.function(state.import_rule, "url")}
  end

  defp feed_symbol(%{import_rule: nil} = state, _char), do: state

  defp feed_symbol(state, char) do
    %{state | import_rule: ImportRule.symbol(state.import_rule, char)}
  end

  defp hash_import(%{import_rule: nil} = state), do: state

  defp hash_import(state) do
    %{state | import_rule: ImportRule.symbol(state.import_rule, ?#)}
  end

  defp import?(%{import_rule: rule}) when is_map(rule), do: true
  defp import?(_state), do: false

  defp var_frame?(%{stack: [{:var, _stage, _name, _fallback} | _]}), do: true
  defp var_frame?(_state), do: false

  defp fallback_context?(%{stack: stack}), do: Enum.any?(stack, &fallback_frame?/1)
  defp fallback_frame?({:var, :fallback, _name, _fallback}), do: true
  defp fallback_frame?(_frame), do: false

  defp suppressed?(%{suppress_depth: depth, depth: current}) when is_integer(depth),
    do: current >= depth

  defp suppressed?(_state), do: false

  defp condition?(%{condition_depth: depth, depth: current}) when is_integer(depth),
    do: depth == current

  defp condition?(_state), do: false

  defp initial?(%{
         property: %{depth: depth},
         depth: current,
         value?: true,
         decl_name: "initial-value"
       })
       when current >= depth,
       do: true

  defp initial?(_state), do: false

  defp capture_syntax(state, token) do
    if syntax_value?(state) do
      %{state | property: %{state.property | syntax_url?: String.trim(token.value) == "<url>"}}
    else
      state
    end
  end

  defp syntax_value?(%{
         property: %{depth: depth},
         depth: current,
         value?: true,
         decl_name: "syntax"
       })
       when current >= depth,
       do: true

  defp syntax_value?(_state), do: false

  defp finish_token(state, changes) do
    state
    |> Map.merge(changes)
    |> Map.merge(%{at_rule: nil, src_pending?: false})
  end

  defp finish_ident(state, changes \\ %{}) do
    state
    |> Map.merge(changes)
    |> Map.put(:at_rule, namespace_prelude(state.at_rule))
  end

  defp namespace_prelude(:namespace), do: :namespace
  defp namespace_prelude(_rule), do: nil

  defp candidate?([{:image_set, true} | _]), do: true
  defp candidate?([{:image, true} | _]), do: true
  defp candidate?(_stack), do: false
  defp image_set_candidate?([{:image_set, true} | _]), do: true
  defp image_set_candidate?(_stack), do: false
  defp used_candidate([{:image_set, _candidate} | tail]), do: [{:image_set, false} | tail]
  defp used_candidate([{:image, _candidate} | tail]), do: [{:image, false} | tail]
  defp used_candidate(stack), do: stack
  defp next_candidate([{:image_set, _candidate} | tail]), do: [{:image_set, true} | tail]
  defp next_candidate([{:image, _candidate} | tail]), do: [{:image, true} | tail]
  defp next_candidate(stack), do: stack
  defp consume_hash([{:image, _candidate} | _tail] = stack), do: stack
  defp consume_hash(stack), do: used_candidate(stack)

  defp bare_url?(value) do
    String.contains?(value, ["/", "."]) and
      not Regex.match?(~r/^\d+(\.\d+)?(x|dpi|dppx)$/i, value)
  end
end
