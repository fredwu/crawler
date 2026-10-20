defmodule Crawler.Parser.CssParser.Scanner do
  @moduledoc false

  alias Crawler.Parser.CssParser.Identifier
  alias Crawler.Parser.CssParser.Value

  require Identifier

  def resources(body), do: body |> scan() |> Map.fetch!(:resources) |> Enum.reverse()
  def comment_spans(body), do: body |> scan() |> Map.fetch!(:comments)

  defp scan(body) do
    walk(body, 0, %{
      stack: [],
      import?: false,
      resources: [],
      comments: [],
      depth: 0,
      font_depth: nil,
      font_src?: false,
      src_pending?: false,
      at_rule: nil
    })
  end

  defp walk(body, offset, state) do
    {body, offset, comments} = Value.trivia(body, offset)
    step(body, offset, %{state | comments: comments ++ state.comments})
  end

  defp step(<<>>, _offset, state), do: state

  defp step(<<"@", body::binary>>, offset, state) do
    {word, tail} = Identifier.take(body)
    finish = offset + 1 + byte_size(body) - byte_size(tail)
    name = String.downcase(word, :ascii)

    walk(tail, finish, %{
      state
      | import?: name == "import",
        at_rule: at_name(name),
        src_pending?: false
    })
  end

  defp step(<<"{", tail::binary>>, offset, state) do
    walk(tail, offset + 1, open_block(state))
  end

  defp step(<<"}", tail::binary>>, offset, state) do
    walk(tail, offset + 1, close_block(state))
  end

  defp step(<<";", tail::binary>>, offset, state) do
    walk(tail, offset + 1, end_declaration(state))
  end

  defp step(<<":", tail::binary>>, offset, state) do
    walk(tail, offset + 1, mark_src(state))
  end

  defp step(<<"#", body::binary>>, offset, state) do
    {_name, tail} = Identifier.take(body)
    finish = offset + 1 + byte_size(body) - byte_size(tail)
    walk(tail, finish, finish_token(state, %{stack: consume_hash(state.stack)}))
  end

  defp step(<<")", tail::binary>>, offset, state) do
    stack = state.stack |> Enum.drop(1) |> used_candidate()
    walk(tail, offset + 1, finish_token(state, %{stack: stack}))
  end

  defp step(<<",", tail::binary>>, offset, state) do
    walk(tail, offset + 1, finish_token(state, %{stack: next_candidate(state.stack)}))
  end

  defp step(<<"(", tail::binary>>, offset, state) do
    walk(tail, offset + 1, finish_token(state, %{stack: [:other | state.stack]}))
  end

  defp step(body, offset, state) do
    case Value.quote_info(body) do
      nil ->
        code(body, offset, state)

      _ ->
        {token, tail, finish, valid?} = Value.quoted(body, offset)

        state =
          if valid? and (state.import? or candidate?(state.stack)),
            do: add(state, token),
            else: state

        walk(tail, finish, finish_token(state, %{stack: used_candidate(state.stack)}))
    end
  end

  defp code(<<byte, _rest::binary>> = body, offset, state)
       when Identifier.name_byte(byte) or byte == ?\\ do
    {word, tail} = Identifier.take(body)
    finish = offset + byte_size(body) - byte_size(tail)

    case tail do
      <<"(", inner::binary>> -> function(String.downcase(word, :ascii), inner, finish + 1, state)
      _ -> atom(body, tail, offset, finish, state)
    end
  end

  defp code(body, offset, state) do
    <<_byte, tail::binary>> = body
    atom(body, tail, offset, offset + 1, state)
  end

  defp function("url", body, offset, state) do
    {token, tail, finish, comments} = Value.url(body, offset)
    state = if token, do: add(state, token), else: state

    walk(
      tail,
      finish,
      finish_token(state, %{
        stack: used_candidate(state.stack),
        comments: comments ++ state.comments
      })
    )
  end

  defp function(name, body, offset, state) do
    walk(body, offset, finish_token(state, %{stack: [function_frame(name) | state.stack]}))
  end

  defp function_frame(name) when name in ["image-set", "-webkit-image-set"],
    do: {:image_set, true}

  defp function_frame("image"), do: {:image, true}
  defp function_frame(_name), do: :other

  # image-set() accepts a bare URL. image() accepts a string or url() only.
  defp atom(body, tail, offset, finish, state) do
    state = note_ident(state, ident_word(body, tail, offset, finish))

    if image_set_candidate?(state.stack) do
      {token, tail, finish} = Value.bare(body, offset)
      state = if bare_url?(token.value), do: add(state, token), else: state
      walk(tail, finish, finish_ident(state, %{stack: used_candidate(state.stack)}))
    else
      walk(tail, finish, finish_ident(state))
    end
  end

  defp add(state, %{value: ""}), do: state

  defp add(state, token) do
    %{state | resources: [Map.put(token, :kind, resource_kind(state)) | state.resources]}
  end

  defp resource_kind(%{font_src?: true}), do: :font
  defp resource_kind(%{import?: true}), do: :import
  defp resource_kind(_state), do: :url

  defp at_name("font-face"), do: :font_face
  defp at_name(_name), do: nil

  defp open_block(state) do
    depth = state.depth + 1

    %{
      state
      | depth: depth,
        font_depth: opened_font_depth(state, depth),
        at_rule: nil,
        import?: false,
        src_pending?: false
    }
  end

  defp opened_font_depth(%{at_rule: :font_face, font_depth: nil}, depth), do: depth
  defp opened_font_depth(state, _depth), do: state.font_depth

  defp close_block(state) do
    closed_font? = state.font_depth == state.depth

    %{
      state
      | depth: max(state.depth - 1, 0),
        font_depth: closed_font(state.font_depth, closed_font?),
        font_src?: state.font_src? and not closed_font?,
        import?: false,
        src_pending?: false,
        at_rule: nil
    }
  end

  defp closed_font(_depth, true), do: nil
  defp closed_font(depth, false), do: depth

  defp end_declaration(state) do
    %{state | font_src?: false, src_pending?: false, import?: false, at_rule: nil}
  end

  defp mark_src(state) do
    %{
      state
      | font_src?: state.font_src? or src_descriptor?(state),
        src_pending?: false,
        import?: false,
        at_rule: nil
    }
  end

  defp src_descriptor?(state), do: state.src_pending? and font_face?(state)

  defp font_face?(%{font_depth: depth, depth: current}) when is_integer(depth),
    do: current >= depth

  defp font_face?(_state), do: false

  defp note_ident(state, word) when is_binary(word) do
    if String.downcase(word, :ascii) == "src" and font_face?(state) do
      %{state | src_pending?: true}
    else
      %{state | src_pending?: false}
    end
  end

  defp note_ident(state, _word), do: %{state | src_pending?: false}

  defp ident_word(body, tail, offset, finish) do
    taken = finish - offset

    if taken > 0 and taken == byte_size(body) - byte_size(tail) do
      case Identifier.take(body) do
        {word, ^tail} when word != "" -> word
        _other -> nil
      end
    end
  end

  defp finish_token(state, changes) do
    state
    |> Map.merge(changes)
    |> Map.merge(%{import?: false, at_rule: nil, src_pending?: false})
  end

  defp finish_ident(state, changes \\ %{}) do
    state
    |> Map.merge(changes)
    |> Map.merge(%{import?: false, at_rule: nil})
  end

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
