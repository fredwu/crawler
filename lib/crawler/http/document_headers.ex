defmodule Crawler.HTTP.DocumentHeaders do
  @moduledoc false

  alias Crawler.Analysis.Budget

  # Native tuple sizes exclude shared literal names and synthesized HTML records.
  @element_bytes 32
  @attribute_bytes 24
  @token_byte_overlap 4

  def elements(headers) do
    case elements_result(headers, Budget.unlimited()) do
      {:ok, elements, _budget} -> elements
      {:error, _reason} -> []
    end
  end

  def elements_result(headers, %Budget{} = budget) when is_list(headers) do
    with {:ok, acc, budget} <- header_elements(headers, "refresh", [], budget),
         {:ok, acc, budget} <- header_elements(headers, "link", acc, budget) do
      elements = Enum.reverse(acc)

      with {:ok, budget} <- Budget.release(budget, Budget.cost(:list_cell, length(acc))),
           do: {:ok, elements, budget}
    end
  end

  def elements_result(_headers, %Budget{} = budget), do: {:ok, [], budget}

  defp header_elements([], _name, acc, budget), do: {:ok, acc, budget}

  defp header_elements([{key, value} | rest], name, acc, budget) when is_binary(value) do
    with {:ok, matches, budget} <- name_matches_result(key, name, budget),
         {:ok, acc, budget} <- header_value(matches, name, value, acc, budget) do
      header_elements(rest, name, acc, budget)
    end
  end

  defp header_elements([_other | rest], name, acc, budget),
    do: header_elements(rest, name, acc, budget)

  defp header_value(false, _name, _value, acc, budget), do: {:ok, acc, budget}

  defp header_value(true, "refresh", value, acc, budget) do
    scratch = Budget.cost(:frame) + Budget.cost(:binary) + byte_size(value)

    with {:ok, budget} <- Budget.count(budget, :facts),
         {:ok, budget} <- Budget.reserve(budget, scratch) do
      result =
        if blank?(value),
          do: {:ok, acc, budget},
          else: emit_element("meta", [{"http-equiv", "refresh"}, {"content", value}], acc, budget)

      release_result(result, scratch)
    end
  end

  defp header_value(true, "link", value, acc, budget),
    do: split_outside(value, ?,, acc, budget, &link_element/3, 1)

  defp link_element(value, acc, budget) do
    scratch = Budget.cost(:frame) + Budget.cost(:binary, 4) + byte_size(value) * 2

    with {:ok, budget} <- Budget.reserve(budget, scratch) do
      result =
        case uri_and_params(String.trim(value)) do
          {url, params} ->
            with {:ok, {attrs, held}, budget} <-
                   split_outside(params, ?;, {%{}, 0}, budget, &put_param/3, 2),
                 {:ok, acc, budget} <- link_element(attrs, url, acc, budget),
                 {:ok, budget} <- Budget.release(budget, held) do
              {:ok, acc, budget}
            end

          :error ->
            {:ok, acc, budget}
        end

      release_result(result, scratch)
    end
  end

  defp link_element(%{"rel" => rel} = attrs, url, acc, budget) when is_binary(rel) do
    with {:ok, budget} <- Budget.reserve(budget, Budget.cost(:frame, 2)) do
      attributes = link_attributes(rel, url, attrs)
      result = emit_element("link", attributes, acc, budget)
      release_result(result, Budget.cost(:frame, 2))
    end
  end

  defp link_element(_attrs, _url, acc, budget), do: {:ok, acc, budget}

  defp link_attributes(rel, url, attrs) do
    [{"rel", rel}, {"href", url}]
    |> param("as", attrs)
    |> param("imagesrcset", attrs)
    |> param("type", attrs)
    |> param("crossorigin", attrs)
  end

  defp param(attributes, name, attrs) do
    case attrs[name] do
      value when is_binary(value) -> attributes ++ [{name, value}]
      _other -> attributes
    end
  end

  defp emit_element(name, attributes, acc, budget) do
    with {:ok, budget} <-
           Budget.charge(budget, @element_bytes + Budget.cost(:list_cell), facts: 1),
         {:ok, budget} <- Budget.reserve(budget, Budget.cost(:list_cell)),
         {:ok, attributes, budget} <- copy_attributes(attributes, [], budget) do
      {:ok, [{name, attributes, []} | acc], budget}
    end
  end

  defp copy_attributes([], acc, budget) do
    attributes = Enum.reverse(acc)

    with {:ok, budget} <- Budget.release(budget, Budget.cost(:list_cell, length(acc))),
         do: {:ok, attributes, budget}
  end

  defp copy_attributes([{name, value} | rest], acc, budget) do
    bytes = @attribute_bytes + Budget.cost(:list_cell) + Budget.cost(:binary) + byte_size(value)

    with {:ok, budget} <- Budget.charge(budget, bytes, facts: 1),
         {:ok, budget} <- Budget.reserve(budget, Budget.cost(:list_cell)) do
      copy_attributes(rest, [{name, :binary.copy(value)} | acc], budget)
    end
  end

  defp put_param(param, {attrs, held}, budget) do
    scratch = Budget.cost(:frame) + Budget.cost(:binary, 8) + byte_size(param) * 6

    with {:ok, budget} <- Budget.reserve(budget, scratch) do
      result =
        case param_pair(param) do
          {name, value} ->
            if Map.has_key?(attrs, name) do
              {:ok, {attrs, held}, budget}
            else
              bytes = Budget.cost(:map_entry, 2) + Budget.cost(:binary) + byte_size(value)

              with {:ok, budget} <- Budget.reserve(budget, bytes) do
                {:ok, {Map.put(attrs, name, :binary.copy(value)), held + bytes}, budget}
              end
            end

          _other ->
            {:ok, {attrs, held}, budget}
        end

      release_result(result, scratch)
    end
  end

  defp param_pair(param) do
    case String.split(String.trim(param), "=", parts: 2) do
      [name, value] ->
        name
        |> String.trim()
        |> String.downcase(:ascii)
        |> named_param(decode_param(value))

      [name] ->
        name |> String.trim() |> String.downcase(:ascii) |> named_flag()

      _other ->
        nil
    end
  end

  defp named_flag("crossorigin"), do: {"crossorigin", ""}
  defp named_flag(_name), do: nil

  defp named_param("type", nil), do: {"type", ""}
  defp named_param("crossorigin", nil), do: {"crossorigin", ""}
  defp named_param(_name, nil), do: nil
  defp named_param("rel", value), do: {"rel", value}
  defp named_param("as", value), do: {"as", value}
  defp named_param("imagesrcset", value), do: {"imagesrcset", value}
  defp named_param("type", value), do: {"type", value}
  defp named_param("crossorigin", value), do: {"crossorigin", value}
  defp named_param(_name, _value), do: nil

  defp uri_and_params(<<"<", rest::binary>>) do
    case :binary.split(rest, ">") do
      [url, params] -> {url, params}
      _ -> :error
    end
  end

  defp uri_and_params(_value), do: :error

  defp decode_param(value) do
    value = value |> String.trim() |> unescape_quoted()
    if value == "", do: nil, else: value
  end

  defp unescape_quoted(<<?", rest::binary>>) do
    String.trim_trailing(rest, "\"")
  end

  defp unescape_quoted(value), do: value

  def name_matches_result(key, name, budget) when is_binary(key),
    do: {:ok, name_matches?(key, name), budget}

  def name_matches_result(key, name, budget) when is_atom(key) do
    scratch = Budget.cost(:binary) + 1024

    with {:ok, budget} <- Budget.reserve(budget, scratch) do
      matches = name_matches?(Atom.to_string(key), name)
      with {:ok, budget} <- Budget.release(budget, scratch), do: {:ok, matches, budget}
    end
  end

  def name_matches_result(key, name, budget) when is_list(key),
    do: name_chars(key, name, [], budget)

  def name_matches_result(key, _name, budget) when is_integer(key) or is_float(key),
    do: {:ok, false, budget}

  def name_matches_result(_key, _name, _budget), do: {:error, :unsupported_header_name}

  defp name_matches?(<<>>, <<>>), do: true

  defp name_matches?(<<char::utf8, rest::binary>>, <<expected, tail::binary>>) do
    lower_char(char) == expected and name_matches?(rest, tail)
  end

  defp name_matches?(_key, _name), do: false
  defp lower_char(char) when char in ?A..?Z, do: char + 32
  # Unicode lowercasing maps the Kelvin sign to the ASCII k in "link".
  defp lower_char(0x212A), do: ?k
  defp lower_char(char), do: char

  defp name_chars([], name, [], budget), do: {:ok, name == "", budget}

  defp name_chars([], name, [rest | pending], budget) do
    with {:ok, budget} <- Budget.release(budget, Budget.cost(:frame)),
         do: name_chars(rest, name, pending, budget)
  end

  defp name_chars([char | rest], <<expected, tail::binary>>, pending, budget)
       when is_integer(char) do
    if lower_char(char) == expected,
      do: name_chars(rest, tail, pending, budget),
      else: finish_name(false, pending, budget)
  end

  defp name_chars([part | rest], name, pending, budget) when is_list(part) or is_binary(part) do
    with {:ok, budget} <- Budget.reserve(budget, Budget.cost(:frame)),
         do: name_chars(part, name, [rest | pending], budget)
  end

  defp name_chars(<<>>, name, pending, budget), do: name_chars([], name, pending, budget)

  defp name_chars(<<char::utf8, rest::binary>>, <<expected, tail::binary>>, pending, budget) do
    if lower_char(char) == expected,
      do: name_chars(rest, tail, pending, budget),
      else: finish_name(false, pending, budget)
  end

  defp name_chars(_key, _name, pending, budget), do: finish_name(false, pending, budget)

  defp finish_name(matches, pending, budget) do
    with {:ok, budget} <- Budget.release(budget, Budget.cost(:frame, length(pending))),
         do: {:ok, matches, budget}
  end

  defp blank?(value), do: String.trim(value) == ""

  defp split_outside(value, separator, acc, budget, emit, facts) do
    # The token and its growth reservation stay live during the child reducer.
    scratch = Budget.cost(:token) + Budget.cost(:binary, 2) + Budget.cost(:frame)

    with {:ok, budget} <- Budget.count(budget, :facts, facts),
         {:ok, budget} <- Budget.reserve(budget, scratch) do
      split_outside(value, separator, <<>>, false, 0, acc, budget, emit, scratch, facts)
    end
  end

  defp split_outside(
         <<>>,
         _separator,
         current,
         _quoted,
         _angles,
         acc,
         budget,
         emit,
         scratch,
         _facts
       ),
       do: release_result(emit.(current, acc, budget), scratch)

  defp split_outside(
         <<?\\, char, rest::binary>>,
         separator,
         current,
         true,
         angles,
         acc,
         budget,
         emit,
         scratch,
         facts
       ),
       do:
         append_token(
           rest,
           separator,
           current,
           char,
           true,
           angles,
           acc,
           budget,
           emit,
           scratch,
           facts
         )

  defp split_outside(
         <<?", rest::binary>>,
         separator,
         current,
         quoted,
         0,
         acc,
         budget,
         emit,
         scratch,
         facts
       ),
       do:
         append_token(
           rest,
           separator,
           current,
           ?",
           not quoted,
           0,
           acc,
           budget,
           emit,
           scratch,
           facts
         )

  defp split_outside(
         <<?<, rest::binary>>,
         separator,
         current,
         false,
         angles,
         acc,
         budget,
         emit,
         scratch,
         facts
       ),
       do:
         append_token(
           rest,
           separator,
           current,
           ?<,
           false,
           angles + 1,
           acc,
           budget,
           emit,
           scratch,
           facts
         )

  defp split_outside(
         <<?>, rest::binary>>,
         separator,
         current,
         false,
         angles,
         acc,
         budget,
         emit,
         scratch,
         facts
       )
       when angles > 0,
       do:
         append_token(
           rest,
           separator,
           current,
           ?>,
           false,
           angles - 1,
           acc,
           budget,
           emit,
           scratch,
           facts
         )

  defp split_outside(
         <<separator, rest::binary>>,
         separator,
         current,
         false,
         0,
         acc,
         budget,
         emit,
         scratch,
         facts
       ) do
    with {:ok, acc, budget} <- release_result(emit.(current, acc, budget), scratch),
         do: split_outside(rest, separator, acc, budget, emit, facts)
  end

  defp split_outside(
         <<char, rest::binary>>,
         separator,
         current,
         quoted,
         angles,
         acc,
         budget,
         emit,
         scratch,
         facts
       ),
       do:
         append_token(
           rest,
           separator,
           current,
           char,
           quoted,
           angles,
           acc,
           budget,
           emit,
           scratch,
           facts
         )

  defp append_token(
         rest,
         separator,
         current,
         char,
         quoted,
         angles,
         acc,
         budget,
         emit,
         scratch,
         facts
       ) do
    with {:ok, budget} <- Budget.reserve(budget, @token_byte_overlap) do
      split_outside(
        rest,
        separator,
        <<current::binary, char>>,
        quoted,
        angles,
        acc,
        budget,
        emit,
        scratch + @token_byte_overlap,
        facts
      )
    end
  end

  defp release_result({:ok, acc, budget}, scratch) do
    with {:ok, budget} <- Budget.release(budget, scratch), do: {:ok, acc, budget}
  end

  defp release_result(error, _scratch), do: error
end
