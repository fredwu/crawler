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
      comments: []
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
    walk(tail, finish, %{state | import?: String.downcase(word, :ascii) == "import"})
  end

  defp step(<<"#", body::binary>>, offset, state) do
    {_name, tail} = Identifier.take(body)
    finish = offset + 1 + byte_size(body) - byte_size(tail)
    walk(tail, finish, %{state | stack: used_candidate(state.stack), import?: false})
  end

  defp step(<<")", tail::binary>>, offset, state) do
    stack = state.stack |> Enum.drop(1) |> used_candidate()
    walk(tail, offset + 1, %{state | stack: stack, import?: false})
  end

  defp step(<<",", tail::binary>>, offset, state) do
    walk(tail, offset + 1, %{state | stack: next_candidate(state.stack), import?: false})
  end

  defp step(<<"(", tail::binary>>, offset, state) do
    walk(tail, offset + 1, %{state | stack: [:other | state.stack], import?: false})
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

        walk(tail, finish, %{state | stack: used_candidate(state.stack), import?: false})
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

    walk(tail, finish, %{
      state
      | stack: used_candidate(state.stack),
        import?: false,
        comments: comments ++ state.comments
    })
  end

  defp function(name, body, offset, state) do
    frame = if name in ["image-set", "-webkit-image-set"], do: {:image_set, true}, else: :other
    walk(body, offset, %{state | stack: [frame | state.stack], import?: false})
  end

  defp atom(body, tail, offset, finish, state) do
    if candidate?(state.stack) do
      {token, tail, finish} = Value.bare(body, offset)
      state = if bare_url?(token.value), do: add(state, token), else: state
      walk(tail, finish, %{state | stack: used_candidate(state.stack), import?: false})
    else
      walk(tail, finish, %{state | import?: false})
    end
  end

  defp add(state, %{value: ""}), do: state
  defp add(state, token), do: %{state | resources: [token | state.resources]}
  defp candidate?([{:image_set, true} | _]), do: true
  defp candidate?(_stack), do: false
  defp used_candidate([{:image_set, _candidate} | tail]), do: [{:image_set, false} | tail]
  defp used_candidate(stack), do: stack
  defp next_candidate([{:image_set, _candidate} | tail]), do: [{:image_set, true} | tail]
  defp next_candidate(stack), do: stack

  defp bare_url?(value) do
    String.contains?(value, ["/", "."]) and
      not Regex.match?(~r/^\d+(\.\d+)?(x|dpi|dppx)$/i, value)
  end
end
