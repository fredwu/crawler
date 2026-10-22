defmodule Crawler.Parser.CssParser.ImportRule do
  @moduledoc false

  def new(emit?) do
    %{
      emit?: emit?,
      declaration?: false,
      valid?: true,
      address: nil,
      phase: :address,
      paren: 0,
      layer?: false,
      layer_open: nil,
      layer_content?: false,
      layer_name: nil,
      supports?: false,
      supports_open: nil,
      supports_content?: false
    }
  end

  def declaration do
    %{new(false) | declaration?: true}
  end

  def address(%{declaration?: true} = rule, token) do
    if declaration_picture?(rule, token) do
      {:picture, rule}
    else
      {:keep, take_address(rule, token)}
    end
  end

  def address(rule, token) do
    {:keep, take_address(rule, token)}
  end

  def ident(rule, word) do
    cond do
      inside_supports?(rule) -> %{rule | supports_content?: true}
      inside_layer?(rule) -> layer_name_ident(rule, word)
      rule.paren > 0 -> rule
      true -> ident_top(rule, word)
    end
  end

  def function(rule, "url") do
    cond do
      inside_supports?(rule) -> %{rule | supports_content?: true}
      inside_layer?(rule) -> %{rule | valid?: false}
      true -> rule
    end
  end

  def function(rule, name) do
    rule =
      cond do
        inside_supports?(rule) -> %{rule | supports_content?: true}
        inside_layer?(rule) -> %{rule | valid?: false}
        rule.paren == 0 -> function_top(rule, name)
        true -> rule
      end

    %{rule | paren: rule.paren + 1}
  end

  def paren(rule) do
    rule = if inside_layer?(rule), do: %{rule | valid?: false}, else: mark_supports(rule)
    %{rule | paren: rule.paren + 1}
  end

  def close_paren(rule) do
    paren = max(rule.paren - 1, 0)
    rule = %{rule | paren: paren}
    rule = close_layer(rule, paren)
    close_supports(rule, paren)
  end

  def comma(rule) do
    cond do
      inside_supports?(rule) -> %{rule | supports_content?: true}
      inside_layer?(rule) -> %{rule | valid?: false}
      rule.paren > 0 -> rule
      rule.phase == :address -> %{rule | valid?: false}
      true -> %{rule | phase: :media}
    end
  end

  def symbol(rule, char) do
    cond do
      inside_supports?(rule) ->
        %{rule | supports_content?: true}

      inside_layer?(rule) and char == ?. and rule.layer_name == :ident ->
        %{rule | layer_name: :dot}

      inside_layer?(rule) ->
        %{rule | valid?: false}

      rule.paren > 0 ->
        rule

      rule.phase == :address ->
        %{rule | valid?: false}

      true ->
        %{rule | phase: :media}
    end
  end

  def finish(rule) do
    if emit?(rule), do: {:emit, rule.address}, else: :drop
  end

  defp emit?(rule) do
    rule.emit? and rule.valid? and rule.paren == 0 and is_nil(rule.layer_open) and
      is_nil(rule.supports_open) and present_address?(rule.address)
  end

  defp present_address?(%{value: value}) when is_binary(value) and value != "", do: true
  defp present_address?(_token), do: false

  defp take_address(rule, nil) do
    cond do
      inside_supports?(rule) ->
        %{rule | supports_content?: true}

      inside_layer?(rule) ->
        %{rule | valid?: false}

      rule.paren > 0 ->
        rule

      rule.phase == :address and is_nil(rule.address) ->
        %{rule | valid?: false, phase: :after_address}

      true ->
        %{rule | valid?: false}
    end
  end

  defp take_address(rule, token) do
    cond do
      inside_supports?(rule) ->
        %{rule | supports_content?: true}

      inside_layer?(rule) ->
        %{rule | valid?: false}

      rule.paren > 0 ->
        rule

      rule.phase == :address and is_nil(rule.address) ->
        %{rule | address: token, phase: :after_address}

      true ->
        %{rule | valid?: false}
    end
  end

  defp ident_top(rule, "layer") do
    if rule.phase == :after_address and not rule.layer? do
      %{rule | layer?: true, phase: :after_layer}
    else
      %{rule | valid?: false}
    end
  end

  defp ident_top(rule, "supports") do
    %{rule | valid?: false}
  end

  defp ident_top(rule, word) do
    cond do
      rule.phase == :address -> %{rule | valid?: false}
      rule.phase == :media and word in ["layer", "supports"] -> %{rule | valid?: false}
      true -> %{rule | phase: :media}
    end
  end

  defp function_top(rule, "layer") do
    if rule.phase == :after_address and not rule.layer? do
      %{
        rule
        | layer?: true,
          layer_open: rule.paren,
          layer_content?: false,
          layer_name: :start,
          phase: :layer
      }
    else
      %{rule | valid?: false, layer?: true}
    end
  end

  defp function_top(rule, "supports") do
    if rule.phase in [:after_address, :after_layer] and not rule.supports? do
      %{
        rule
        | supports?: true,
          supports_open: rule.paren,
          supports_content?: false,
          phase: :supports
      }
    else
      %{rule | valid?: false, supports?: true}
    end
  end

  defp function_top(rule, _name) do
    if rule.phase == :address do
      %{rule | valid?: false}
    else
      %{rule | phase: :media}
    end
  end

  defp close_layer(%{layer_open: paren} = rule, paren) do
    rule = if valid_layer_name?(rule), do: rule, else: %{rule | valid?: false}
    %{rule | layer_open: nil, layer_name: nil, phase: :after_layer}
  end

  defp close_layer(rule, _paren), do: rule

  defp close_supports(%{supports_open: paren} = rule, paren) do
    rule = if rule.supports_content?, do: rule, else: %{rule | valid?: false}
    %{rule | supports_open: nil, phase: :after_supports}
  end

  defp close_supports(rule, _paren), do: rule

  defp mark_supports(rule) do
    if inside_supports?(rule), do: %{rule | supports_content?: true}, else: rule
  end

  defp inside_supports?(%{supports_open: open, paren: paren}) when is_integer(open),
    do: paren > open

  defp inside_supports?(_rule), do: false

  defp inside_layer?(%{layer_open: open, paren: paren}) when is_integer(open), do: paren > open
  defp inside_layer?(_rule), do: false

  # A declaration keeps the import rule so a supports() test and an import block
  # stay inside it. A url() after that one address is an ordinary picture.
  defp declaration_picture?(%{paren: 0, phase: phase}, %{value: value})
       when phase != :address and is_binary(value) and value != "",
       do: true

  defp declaration_picture?(_rule, _token), do: false

  defp layer_name_ident(rule, word) do
    if rule.layer_name in [:start, :dot] and css_ident?(word) do
      %{rule | layer_content?: true, layer_name: :ident}
    else
      %{rule | valid?: false}
    end
  end

  defp valid_layer_name?(rule) do
    rule.valid? and rule.layer_content? and rule.layer_name == :ident
  end

  defp css_ident?(""), do: false
  defp css_ident?("-"), do: false
  defp css_ident?(<<byte, _rest::binary>>) when byte in ?0..?9, do: false
  defp css_ident?(<<"-", byte, _rest::binary>>) when byte in ?0..?9, do: false
  defp css_ident?(word) when is_binary(word), do: true
end
