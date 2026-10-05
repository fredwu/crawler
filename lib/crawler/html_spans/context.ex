defmodule Crawler.HTMLSpans.Context do
  @moduledoc false

  alias Crawler.HTMLSpans

  @html_void ~w(area base br col embed hr img input link meta param source track wbr)
  @svg_integration ~w(foreignobject desc title)
  @math_text ~w(mi mo mn ms mtext)
  @html_scope ~w(applet caption html table td th marquee object select template)
  @table_elements ~w(caption colgroup table tbody td tfoot th thead tr)
  @foreign_breakout ~w(b big blockquote body br center code dd div dl dt em embed h1 h2 h3 h4 h5 h6 head hr i img li listing menu meta nobr ol p pre ruby s small span strong strike sub sup table tt u ul var)

  def in_template?(stack) do
    Enum.any?(stack, &(&1.name == "template" and &1.namespace == :html))
  end

  def foreign?([%{namespace: namespace} | _]), do: namespace != :html
  def foreign?([]), do: false

  def namespace(%{closing?: true, name: name}, stack) do
    stack = closing_context(name, stack)

    case closing_parent(name, stack) do
      nil -> :html
      {parent, _rest} -> parent.namespace
    end
  end

  def namespace(tag, stack) do
    inherited = inherited_namespace(tag, List.first(stack))

    cond do
      tag.name == "svg" and svg_entry?(inherited, stack) -> :svg
      tag.name == "math" and inherited == :html -> :math
      inherited != :html and foreign_breakout?(tag) -> :html
      true -> inherited
    end
  end

  defp svg_entry?(:html, _stack), do: true
  defp svg_entry?(_inherited, [%{namespace: :math, name: "annotation-xml"} | _]), do: true
  defp svg_entry?(_inherited, _stack), do: false

  defp foreign_breakout?(%{name: "font"} = tag) do
    tag.source
    |> HTMLSpans.attributes(0, decode: false)
    |> Enum.any?(&(&1.name in ~w(color face size)))
  end

  defp foreign_breakout?(tag), do: tag.name in @foreign_breakout

  def advance(%{closing?: true, name: name}, _namespace, stack) do
    stack = closing_context(name, stack)

    case closing_parent(name, stack) do
      {_parent, rest} -> rest
      nil -> stack
    end
  end

  def advance(tag, namespace, stack) do
    stack = if namespace == :html, do: leave_foreign(stack), else: stack

    if tag.content_span || (namespace != :html and tag.self_closing?) ||
         (namespace == :html and tag.name in @html_void) do
      stack
    else
      [
        %{name: tag.name, namespace: namespace, html_children?: html_children?(tag, namespace)}
        | stack
      ]
    end
  end

  defp closing_context(name, stack) when name in ["br", "p"], do: leave_foreign(stack)
  defp closing_context(_name, stack), do: stack

  defp closing_parent(name, stack) do
    foreign_parent(name, stack) || html_parent(name, stack)
  end

  defp foreign_parent(_name, [%{namespace: :html} | _]), do: nil
  defp foreign_parent(name, [%{name: name} = node | rest]), do: {node, rest}
  defp foreign_parent(name, [_node | rest]), do: foreign_parent(name, rest)
  defp foreign_parent(_name, []), do: nil

  defp html_parent(name, [%{namespace: :html, name: name} = node | rest]), do: {node, rest}

  defp html_parent("template", [_node | rest]), do: html_parent("template", rest)

  defp html_parent(name, [node | rest]) do
    if scope_barrier?(node, name), do: nil, else: html_parent(name, rest)
  end

  defp html_parent(_name, []), do: nil

  defp scope_barrier?(%{namespace: :html, name: name}, target) when target in @table_elements,
    do: name in ~w(html table template)

  defp scope_barrier?(%{namespace: :html, name: name}, target),
    do:
      name in @html_scope or (target == "p" and name == "button") or
        (target == "li" and name in ~w(ol ul))

  defp scope_barrier?(%{namespace: :math, name: name}, _target),
    do: name in @math_text or name == "annotation-xml"

  defp scope_barrier?(%{namespace: :svg, name: name}, _target),
    do: name in @svg_integration

  defp inherited_namespace(_tag, nil), do: :html

  defp inherited_namespace(tag, %{namespace: :math, name: name}) when name in @math_text do
    if tag.name in ~w(mglyph malignmark), do: :math, else: :html
  end

  defp inherited_namespace(_tag, %{html_children?: true}), do: :html
  defp inherited_namespace(_tag, parent), do: parent.namespace

  defp html_children?(%{name: name}, :svg), do: name in @svg_integration

  defp html_children?(%{name: name}, :math) when name in @math_text, do: true

  defp html_children?(%{name: "annotation-xml"} = tag, :math) do
    tag.source
    |> HTMLSpans.attributes(0, decode: false)
    |> Enum.find_value("", fn attr -> if attr.name == "encoding", do: attr.value end)
    |> then(fn value -> if String.valid?(value), do: HTMLSpans.decode(value), else: value end)
    |> String.downcase(:ascii)
    |> then(&(&1 in ["text/html", "application/xhtml+xml"]))
  end

  defp html_children?(_tag, _namespace), do: false

  defp leave_foreign([%{namespace: namespace, html_children?: false} | rest])
       when namespace != :html,
       do: leave_foreign(rest)

  defp leave_foreign(stack), do: stack
end
