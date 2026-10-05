defmodule Crawler.Parser.LinkParser do
  @moduledoc """
  Parses links and transforms them if necessary.
  """

  alias Crawler.HTMLReferences
  alias Crawler.HTMLRefresh
  alias Crawler.MediaType
  alias Crawler.Parser.CssParser
  alias Crawler.Parser.JsParser
  alias Crawler.Parser.LinkParser.LinkExpander
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

  defp emit(tag, attrs, children, opts, handler, namespace) do
    results =
      tag
      |> links(attrs, children, opts, namespace)
      |> Enum.map(fn {attr, link} ->
        role = HTMLReferences.role(tag, attr, attrs)
        goal = reference_goal(tag, attr, attrs, opts)
        {role, goal, LinkExpander.expand({attr_name(attr), link}, opts)}
      end)
      |> Enum.reject(&match?({_role, _goal, nil}, &1))
      |> Enum.uniq_by(fn {role, goal, element} -> {role, goal, raw_link(element)} end)
      |> Enum.map(fn {role, goal, element} ->
        handler.(element, handler_opts(opts, role, goal, tag))
      end)

    case results do
      [] -> nil
      [result] -> result
      results -> results
    end
  end

  defp links(tag, attrs, children, opts, namespace) do
    attributes =
      tag
      |> HTMLReferences.attributes(attrs, opts, namespace)
      |> Enum.flat_map(fn name -> attribute_links(name, HTMLReferences.attribute(attrs, name)) end)

    attributes ++ source_links(tag, attrs, children, opts, namespace)
  end

  defp source_links("style", _attrs, children, opts, :html) do
    if HTMLReferences.enabled?(opts, "css"),
      do: children |> raw_text() |> style_links("style_text"),
      else: []
  end

  defp source_links("script", attrs, children, opts, :html) do
    if HTMLReferences.enabled?(opts, "js") and HTMLReferences.script_source(attrs) == :inline do
      children
      |> raw_text()
      |> JsParser.specs(HTMLReferences.script_goal(attrs))
      |> Enum.map(&{"href", &1})
    else
      []
    end
  end

  defp source_links(_tag, _attrs, _children, _opts, _namespace), do: []

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

  defp attribute_links(name, value), do: [{name, value}]

  defp style_links(nil, _attr), do: []
  defp style_links("", _attr), do: []

  defp style_links(css, attr) do
    css
    |> CssParser.parse()
    |> Enum.map(fn {"link", [{"href", url}], _} -> {attr, url} end)
  end

  defp reference_goal(tag, attr, attrs, opts) do
    cond do
      MediaType.javascript?(opts[:content_type]) ->
        :module

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

  defp handler_opts(opts, role, goal, tag) do
    opts =
      opts
      |> Map.delete(:javascript_goal)
      |> Map.put(:html_tag, role)
      |> Map.put(:reference_tag, tag)

    if goal, do: Map.put(opts, :javascript_goal, goal), else: opts
  end

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
