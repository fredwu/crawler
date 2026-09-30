defmodule Crawler.Parser.LinkParser do
  @moduledoc """
  Parses links and transforms them if necessary.
  """

  alias Crawler.MediaType
  alias Crawler.Parser.CssParser
  alias Crawler.Parser.JsParser
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
      link_handler.(element, handler_opts(opts, tag, attr, attrs))
    end)
  end

  defp links("style", _attrs, children, opts) do
    if enabled?(opts, "css"), do: children |> node_text() |> style_links(), else: []
  end

  defp links("script", attrs, children, opts) do
    if enabled?(opts, "js") do
      script_src(attrs) ++ script_imports(attrs, children)
    else
      []
    end
  end

  defp links(tag, attrs, _children, opts) do
    tag
    |> attributes(attrs, opts)
    |> Enum.flat_map(fn name ->
      case attribute(attrs, name) do
        nil -> []
        value -> Enum.map(values(name, value), &{name, &1})
      end
    end)
    |> Kernel.++(style_attribute_links(attrs, opts))
  end

  defp attributes("a", _attrs, _opts), do: ["href"]
  defp attributes("area", _attrs, _opts), do: ["href"]
  defp attributes("iframe", _attrs, _opts), do: ["src"]
  defp attributes("object", _attrs, _opts), do: ["data"]
  defp attributes("embed", _attrs, _opts), do: ["src"]

  defp attributes("meta", attrs, _opts) do
    if refresh?(attrs), do: ["content"], else: []
  end

  defp attributes("link", attrs, opts) do
    cond do
      document_links?(opts) -> ["href"]
      true -> link_attributes(attrs, opts)
    end
  end

  defp attributes("img", _attrs, opts),
    do: media_attributes(opts, ["src", "srcset", "imagesrcset"])

  defp attributes("source", _attrs, opts),
    do: media_attributes(opts, ["src", "srcset", "imagesrcset"])

  defp attributes("video", _attrs, opts), do: media_attributes(opts, ["src", "poster"])
  defp attributes("audio", _attrs, opts), do: media_attributes(opts, ["src"])
  defp attributes("track", _attrs, opts), do: media_attributes(opts, ["src"])
  defp attributes("image", _attrs, opts), do: media_attributes(opts, ["href", "xlink:href"])
  defp attributes("use", _attrs, opts), do: media_attributes(opts, ["href", "xlink:href"])
  defp attributes(_tag, _attrs, _opts), do: []

  defp follow_link?(attrs, opts) do
    rel = rel_tokens(attrs)
    as = attrs |> attribute("as") |> to_string() |> String.downcase()

    cond do
      "stylesheet" in rel -> enabled?(opts, "css")
      "preload" in rel and as == "style" -> enabled?(opts, "css")
      "preload" in rel and as == "font" -> enabled?(opts, "css")
      "preload" in rel and as == "script" -> enabled?(opts, "js")
      "preload" in rel and as == "image" -> enabled?(opts, "images")
      icon_rel?(rel) -> enabled?(opts, "images")
      true -> false
    end
  end

  defp icon_rel?(rel) do
    "icon" in rel or "apple-touch-icon" in rel or "mask-icon" in rel
  end

  defp rel_tokens(attrs) do
    attrs
    |> attribute("rel")
    |> to_string()
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
  end

  defp media_attributes(opts, names) do
    if enabled?(opts, "images"), do: names, else: []
  end

  defp style_attribute_links(attrs, opts) do
    if enabled?(opts, "css"), do: style_links(attribute(attrs, "style")), else: []
  end

  defp enabled?(opts, asset), do: asset in List.wrap(opts[:assets])

  defp document_links?(opts) do
    MediaType.css?(opts[:content_type]) or MediaType.javascript?(opts[:content_type])
  end

  defp link_attributes(attrs, opts) do
    hrefs = if follow_link?(attrs, opts), do: ["href"], else: []
    images = if imagesrcset?(attrs, opts), do: ["imagesrcset"], else: []
    hrefs ++ images
  end

  defp imagesrcset?(attrs, opts) do
    enabled?(opts, "images") and is_binary(attribute(attrs, "imagesrcset"))
  end

  defp refresh?(attrs) do
    attrs
    |> attribute_ci("http-equiv")
    |> to_string()
    |> String.trim()
    |> String.downcase() == "refresh"
  end

  defp script_src(attrs) do
    case attribute(attrs, "src") do
      value when is_binary(value) and value != "" -> [{"src", value}]
      _ -> []
    end
  end

  defp script_imports(attrs, children) do
    if script_source?(attrs) do
      children
      |> raw_text()
      |> JsParser.specs()
      |> Enum.map(&{"href", &1})
    else
      []
    end
  end

  defp script_source?(attrs) do
    type =
      attrs
      |> attribute("type")
      |> to_string()
      |> String.trim()
      |> String.downcase()

    type in ["", "module"] or MediaType.javascript?(type)
  end

  @srcset_candidate ~r/\s*((?i:data):[^\s,]+(?:,[^\s,]+)*|[^,\s]+)(?:\s+[^,]+)?\s*(?:,|$)/

  defp values("srcset", value) do
    @srcset_candidate
    |> Regex.scan(value, capture: :all_but_first)
    |> List.flatten()
    |> Enum.reject(&(&1 == "" or data_url?(&1)))
  end

  defp values("imagesrcset", value), do: values("srcset", value)

  defp values("content", value), do: refresh_targets(value)

  defp values(_name, value), do: [value]

  defp refresh_targets(value) do
    cond do
      match = Regex.run(~r/url\s*=\s*(["'])([^"']*)\1/i, value) ->
        present(Enum.at(match, 2))

      match = Regex.run(~r/url\s*=\s*([^;\s"']+)/i, value) ->
        present(Enum.at(match, 1))

      true ->
        []
    end
  end

  defp present(url) when is_binary(url) do
    # Keep the original text, spaces included, so the saved tag can be
    # rewritten. Resolution trims before the request.
    if String.trim(url) == "", do: [], else: [url]
  end

  defp present(_url), do: []

  defp data_url?(url), do: String.match?(url, ~r/^data:/i)

  defp style_links(nil), do: []
  defp style_links(""), do: []

  defp style_links(css) when is_binary(css) do
    css
    |> CssParser.parse()
    |> Enum.map(fn {"link", [{"href", url}], _} -> {"style", url} end)
  end

  defp node_text(children) do
    children |> raw_text() |> unescape_style()
  end

  # Script text is raw data. HTML does not decode entities there, so a quote
  # entity must not change which imports are real.
  defp raw_text(children) do
    Enum.map_join(children, fn
      text when is_binary(text) -> text
      {_tag, _attrs, inner} -> raw_text(inner)
      _ -> ""
    end)
  end

  defp unescape_style(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#34;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace(~r/&#x0*22;/i, "\"")
    |> String.replace(~r/&#x0*27;/i, "'")
  end

  defp attribute(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  defp attribute_ci(attrs, name) do
    Enum.find_value(attrs, fn
      {key, value} ->
        if String.downcase(to_string(key)) == name, do: value

      _ ->
        nil
    end)
  end

  defp attr_name("style"), do: "href"
  defp attr_name(name), do: name

  defp handler_opts(opts, tag, "href", _attrs) when tag in ["a", "area"],
    do: Map.put(opts, :html_tag, "a")

  defp handler_opts(opts, "iframe", "src", _attrs), do: Map.put(opts, :html_tag, "a")

  defp handler_opts(opts, tag, _attr, _attrs) when tag in ["object", "embed", "meta"],
    do: Map.put(opts, :html_tag, "a")

  defp handler_opts(opts, "track", _attr, _attrs), do: Map.put(opts, :html_tag, "track")
  defp handler_opts(opts, "script", _attr, _attrs), do: Map.put(opts, :html_tag, "script")

  defp handler_opts(opts, tag, _attr, _attrs) when tag in ["image", "use"],
    do: Map.put(opts, :html_tag, "img")

  defp handler_opts(opts, "link", "imagesrcset", _attrs), do: Map.put(opts, :html_tag, "img")
  defp handler_opts(opts, "link", "href", attrs), do: Map.put(opts, :html_tag, link_tag(attrs))

  defp handler_opts(opts, tag, attr, _attrs)
       when attr in ["src", "srcset", "imagesrcset", "poster"] and tag in @media_tags do
    Map.put(opts, :html_tag, tag)
  end

  defp handler_opts(opts, _tag, _attr, _attrs), do: Map.put(opts, :html_tag, "link")

  defp link_tag(attrs) do
    rel = rel_tokens(attrs)
    as = attrs |> attribute("as") |> to_string() |> String.downcase()

    cond do
      "preload" in rel and as == "script" -> "script"
      "preload" in rel and as == "font" -> "font"
      "preload" in rel and as == "image" -> "img"
      icon_rel?(rel) -> "img"
      true -> "link"
    end
  end

  defp raw_link({_src, link}), do: link
  defp raw_link({_tag, link, _src, _url}), do: link
end
