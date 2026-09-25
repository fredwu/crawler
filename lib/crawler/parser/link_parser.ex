defmodule Crawler.Parser.LinkParser do
  @moduledoc """
  Parses links and transforms them if necessary.
  """

  alias Crawler.Parser.CssParser
  alias Crawler.Parser.LinkParser.LinkExpander

  @media_tags ["img", "source", "video", "audio", "script"]

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
  def parse({tag, attrs, children}, opts, link_handler) do
    case emit(tag, attrs, children, opts, link_handler) do
      [] -> nil
      [result] -> result
      results -> results
    end
  end

  defp emit(tag, attrs, children, opts, link_handler) do
    tag
    |> links(attrs, children, opts)
    |> Enum.map(fn {attr, link} ->
      {attr, LinkExpander.expand({attr_name(attr), link}, opts)}
    end)
    |> Enum.reject(&match?({_attr, nil}, &1))
    |> Enum.uniq_by(fn {_attr, element} -> raw_link(element) end)
    |> Enum.map(fn {attr, element} ->
      link_handler.(element, handler_opts(opts, tag, attr))
    end)
  end

  defp links("style", _attrs, children, opts) do
    if enabled?(opts, "css"), do: children |> node_text() |> style_links(), else: []
  end

  defp links(tag, attrs, _children, opts) do
    tag
    |> attributes(opts)
    |> Enum.flat_map(fn name ->
      case attribute(attrs, name) do
        nil -> []
        value -> Enum.map(values(name, value), &{name, &1})
      end
    end)
    |> Kernel.++(style_attribute_links(attrs, opts))
  end

  defp attributes("a", _opts), do: ["href"]

  defp attributes("link", opts) do
    if enabled?(opts, "css") or css_document?(opts), do: ["href"], else: []
  end

  defp attributes("script", opts), do: if(enabled?(opts, "js"), do: ["src"], else: [])
  defp attributes("img", opts), do: media_attributes(opts, ["src", "srcset"])
  defp attributes("source", opts), do: media_attributes(opts, ["src", "srcset"])
  defp attributes("video", opts), do: media_attributes(opts, ["src", "poster"])
  defp attributes("audio", opts), do: media_attributes(opts, ["src"])
  defp attributes(_tag, _opts), do: []

  defp media_attributes(opts, names) do
    if enabled?(opts, "images"), do: names, else: []
  end

  defp style_attribute_links(attrs, opts) do
    if enabled?(opts, "css"), do: style_links(attribute(attrs, "style")), else: []
  end

  defp enabled?(opts, asset), do: asset in List.wrap(opts[:assets])

  defp css_document?(opts), do: String.starts_with?(to_string(opts[:content_type]), "text/css")

  @srcset_candidate ~r/\s*((?i:data):[^\s,]+(?:,[^\s,]+)*|[^,\s]+)(?:\s+[^,]+)?\s*(?:,|$)/

  defp values("srcset", value) do
    @srcset_candidate
    |> Regex.scan(value, capture: :all_but_first)
    |> List.flatten()
    |> Enum.reject(&(&1 == "" or data_url?(&1)))
  end

  defp values(_name, value), do: [value]

  defp data_url?(url), do: String.match?(url, ~r/^data:/i)

  defp style_links(nil), do: []
  defp style_links(""), do: []

  defp style_links(css) when is_binary(css) do
    css
    |> CssParser.parse()
    |> Enum.map(fn {"link", [{"href", url}], _} -> {"style", url} end)
  end

  defp node_text(children) do
    children
    |> Enum.map_join(fn
      text when is_binary(text) -> text
      {_tag, _attrs, inner} -> node_text(inner)
      _ -> ""
    end)
    |> unescape_style()
  end

  defp unescape_style(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#34;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace(~r/&#x27;/i, "'")
  end

  defp attribute(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  defp attr_name("style"), do: "href"
  defp attr_name(name), do: name

  defp handler_opts(opts, "a", "href"), do: Map.put(opts, :html_tag, "a")

  defp handler_opts(opts, tag, attr)
       when attr in ["src", "srcset", "poster"] and tag in @media_tags do
    Map.put(opts, :html_tag, tag)
  end

  defp handler_opts(opts, _tag, _attr), do: Map.put(opts, :html_tag, "link")

  defp raw_link({_src, link}), do: link
  defp raw_link({_tag, link, _src, _url}), do: link
end
