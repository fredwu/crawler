defmodule Crawler.HTMLReferences do
  @moduledoc false

  alias Crawler.MediaType

  def attributes(tag, attrs, opts, namespace \\ :html) do
    names = element_attributes(tag, attrs, opts, namespace)

    if enabled?(opts, "css") and attribute(attrs, "style") != nil,
      do: names ++ ["style"],
      else: names
  end

  def enabled?(opts, channel), do: channel in List.wrap(opts[:assets])

  def script_source(attrs) do
    cond do
      not executable_script?(attrs) -> :none
      attribute(attrs, "src") != nil -> :external
      true -> :inline
    end
  end

  def executable_script?(attrs) do
    type = attrs |> script_type() |> String.downcase(:ascii)
    type == "module" or (MediaType.javascript?(type) and MediaType.normalize(type) == type)
  end

  def script_goal(attrs) do
    type = attrs |> script_type() |> String.downcase(:ascii)
    if type == "module", do: :module, else: :script
  end

  def preload_goal(attrs) do
    if "modulepreload" in rel_tokens(attrs), do: :module, else: :script
  end

  defp script_type(attrs) do
    case attribute(attrs, "type") do
      "" -> "text/javascript"
      nil -> language_type(attribute(attrs, "language"))
      type -> Regex.replace(~r/^[\t\n\f\r ]+|[\t\n\f\r ]+$/, type, "")
    end
  end

  defp language_type(language) when language in [nil, ""], do: "text/javascript"
  defp language_type(language), do: "text/" <> language

  def role(_tag, "style", _attrs), do: "link"
  def role(_tag, "style_text", _attrs), do: "link"
  def role("script", _attr, _attrs), do: "script"

  def role(tag, _attr, _attrs) when tag in ["a", "area", "iframe", "object", "embed", "meta"],
    do: "a"

  def role(tag, _attr, _attrs) when tag in ["image", "use"], do: "img"
  def role("link", "imagesrcset", _attrs), do: "img"
  def role("link", "href", attrs), do: link_role(attrs)
  def role(tag, _attr, _attrs) when tag in ["img", "source", "video", "audio", "track"], do: tag
  def role(_tag, _attr, _attrs), do: "link"

  def integrity_resource?("script", attrs), do: script_source(attrs) == :external

  def integrity_resource?("link", attrs) do
    rel = rel_tokens(attrs)
    as = normalized(attrs, "as")

    Enum.any?(rel, &(&1 in ["stylesheet", "modulepreload"])) or
      ("preload" in rel and as in ["script", "style"])
  end

  def integrity_resource?(_tag, _attrs), do: false

  def active_attributes(attrs), do: Enum.uniq_by(attrs, &elem(&1, 0))

  def attribute(attrs, name) do
    Enum.find_value(attrs, fn {key, value} ->
      if String.downcase(to_string(key), :ascii) == name, do: value
    end)
  end

  defp element_attributes("a", attrs, _opts, :svg), do: svg_href(attrs)

  defp element_attributes(tag, attrs, opts, :svg) when tag in ["image", "use"],
    do: channel_attributes(opts, "images", svg_href(attrs))

  defp element_attributes(_tag, _attrs, _opts, namespace) when namespace != :html, do: []
  defp element_attributes(tag, _attrs, _opts, :html) when tag in ["a", "area"], do: ["href"]
  defp element_attributes(tag, _attrs, _opts, :html) when tag in ["iframe", "embed"], do: ["src"]
  defp element_attributes("object", _attrs, _opts, :html), do: ["data"]

  defp element_attributes("meta", attrs, _opts, :html),
    do: if(normalized(attrs, "http-equiv") == "refresh", do: ["content"], else: [])

  defp element_attributes("script", attrs, opts, :html) do
    if enabled?(opts, "js") and script_source(attrs) == :external, do: ["src"], else: []
  end

  defp element_attributes("link", attrs, opts, :html) do
    href = if document_links?(opts) or link_enabled?(attrs, opts), do: ["href"], else: []

    images =
      if image_preload?(attrs), do: channel_attributes(opts, "images", ["imagesrcset"]), else: []

    href ++ images
  end

  defp element_attributes(tag, _attrs, opts, :html) when tag in ["img", "source"],
    do: channel_attributes(opts, "images", ["src", "srcset"])

  defp element_attributes("video", _attrs, opts, :html),
    do: channel_attributes(opts, "images", ["src", "poster"])

  defp element_attributes(tag, _attrs, opts, :html) when tag in ["audio", "track"],
    do: channel_attributes(opts, "images", ["src"])

  defp element_attributes(_tag, _attrs, _opts, :html), do: []

  defp channel_attributes(opts, channel, names) do
    if enabled?(opts, channel), do: names, else: []
  end

  defp svg_href(attrs) do
    if attribute(attrs, "href") == nil, do: ["xlink:href"], else: ["href"]
  end

  defp image_preload?(attrs) do
    "preload" in rel_tokens(attrs) and normalized(attrs, "as") == "image"
  end

  defp document_links?(opts),
    do: MediaType.css?(opts[:content_type]) or MediaType.javascript?(opts[:content_type])

  defp link_enabled?(attrs, opts) do
    rel = rel_tokens(attrs)
    as = normalized(attrs, "as")

    cond do
      "modulepreload" in rel -> enabled?(opts, "js")
      "stylesheet" in rel -> enabled?(opts, "css")
      "preload" in rel and as in ["style", "font"] -> enabled?(opts, "css")
      "preload" in rel and as == "script" -> enabled?(opts, "js")
      "preload" in rel and as == "image" -> enabled?(opts, "images")
      icon_rel?(rel) -> enabled?(opts, "images")
      true -> false
    end
  end

  defp link_role(attrs) do
    rel = rel_tokens(attrs)
    as = normalized(attrs, "as")

    cond do
      "modulepreload" in rel -> "script"
      "preload" in rel and as == "script" -> "script"
      "preload" in rel and as == "font" -> "font"
      "preload" in rel and as == "image" -> "img"
      icon_rel?(rel) -> "img"
      true -> "link"
    end
  end

  defp icon_rel?(rel), do: Enum.any?(rel, &(&1 in ["icon", "apple-touch-icon", "mask-icon"]))

  defp rel_tokens(attrs),
    do:
      attrs
      |> normalized("rel")
      |> String.split(~r/[\t\n\f\r ]+/, trim: true)

  defp normalized(attrs, name),
    do: attrs |> attribute(name) |> to_string() |> String.downcase(:ascii)
end
