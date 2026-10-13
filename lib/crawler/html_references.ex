defmodule Crawler.HTMLReferences do
  @moduledoc false

  alias Crawler.MediaType

  @svg_paint ~w(image use feimage lineargradient radialgradient pattern filter)
  @svg_presentation ~w(fill stroke filter clip-path mask marker marker-start marker-mid marker-end cursor)
  @math_inert @svg_paint ++ ~w(base script style svg)

  def attributes(tag, attrs, opts, namespace \\ :html) do
    names = element_attributes(tag, attrs, opts, namespace)
    names = if style_attribute?(attrs, opts), do: names ++ ["style"], else: names

    if namespace == :svg,
      do: names ++ presentation_attributes(attrs, opts),
      else: names
  end

  def presentation_attribute?(name), do: name in @svg_presentation

  def css_style_element?(attrs) do
    case attribute(attrs, "type") do
      nil -> true
      "" -> true
      type -> String.downcase(to_string(type), :ascii) == "text/css"
    end
  end

  def srcdoc_frame?(tag, attrs, namespace) do
    tag == "iframe" and namespace == :html and attribute(attrs, "srcdoc") != nil
  end

  def enabled?(opts, channel), do: channel in List.wrap(opts[:assets])

  def script_source(attrs) do
    cond do
      not executable_script?(attrs) -> :none
      attribute(attrs, "src") != nil -> :external
      true -> :inline
    end
  end

  def svg_script_source(attrs) do
    cond do
      not executable_script?(attrs) -> :none
      attribute(attrs, "href") != nil -> :external
      attribute(attrs, "xlink:href") != nil -> :external
      true -> :inline
    end
  end

  def local_reference?(value) when is_binary(value) do
    value |> String.trim() |> String.starts_with?("#")
  end

  def local_reference?(_value), do: false

  def executable_script?(attrs) do
    type = attrs |> script_type() |> String.downcase(:ascii)

    # `normalize/1` trims Unicode spaces, so a NBSP-padded type must not match
    # merely because its essence is JavaScript. Parameters are still accepted.
    type == "module" or
      (MediaType.javascript?(type) and ascii_essence(type) == MediaType.normalize(type))
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
  def role(_tag, name, _attrs) when name in @svg_presentation, do: "link"
  def role("script", _attr, _attrs), do: "script"

  def role(tag, _attr, _attrs) when tag in ["a", "area", "iframe", "object", "embed", "meta"],
    do: "a"

  def role(tag, _attr, _attrs) when tag in @svg_paint, do: "img"
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

  defp element_attributes("a", attrs, opts, :svg) do
    if skip_link?(attrs, opts), do: [], else: svg_href(attrs)
  end

  defp element_attributes("script", attrs, opts, :svg) do
    if enabled?(opts, "js") and svg_script_source(attrs) == :external do
      svg_href(attrs)
    else
      []
    end
  end

  defp element_attributes(tag, attrs, opts, :svg) when tag in @svg_paint,
    do: channel_attributes(opts, "images", svg_href(attrs))

  defp element_attributes(tag, _attrs, _opts, :math) when tag in @math_inert, do: []

  defp element_attributes(_tag, attrs, opts, :math) do
    cond do
      skip_link?(attrs, opts) -> []
      attribute(attrs, "href") != nil -> ["href"]
      attribute(attrs, "xlink:href") != nil -> ["xlink:href"]
      true -> []
    end
  end

  defp element_attributes(_tag, _attrs, _opts, namespace) when namespace != :html, do: []

  defp element_attributes(tag, attrs, opts, :html) when tag in ["a", "area"] do
    if skip_link?(attrs, opts), do: [], else: ["href"]
  end

  defp element_attributes("iframe", attrs, _opts, :html) do
    if attribute(attrs, "srcdoc") == nil, do: ["src"], else: []
  end

  defp element_attributes("embed", _attrs, _opts, :html), do: ["src"]
  defp element_attributes("object", _attrs, _opts, :html), do: ["data"]

  defp element_attributes("meta", attrs, opts, :html) do
    cond do
      page_nofollow?(opts) -> []
      normalized(attrs, "http-equiv") == "refresh" -> ["content"]
      true -> []
    end
  end

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
      "modulepreload" in rel ->
        enabled?(opts, "js")

      "stylesheet" in rel ->
        enabled?(opts, "css") and acceptable_style_type?(attrs)

      "preload" in rel and as == "style" ->
        enabled?(opts, "css") and acceptable_style_type?(attrs)

      "preload" in rel and as == "font" ->
        enabled?(opts, "css")

      "preload" in rel and as == "script" ->
        enabled?(opts, "js")

      "preload" in rel and as == "image" ->
        enabled?(opts, "images")

      icon_rel?(rel) ->
        enabled?(opts, "images")

      true ->
        false
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

  defp style_attribute?(attrs, opts),
    do: enabled?(opts, "css") and attribute(attrs, "style") != nil

  defp presentation_attributes(attrs, opts) do
    if enabled?(opts, "css"),
      do: Enum.filter(@svg_presentation, &(attribute(attrs, &1) != nil)),
      else: []
  end

  defp acceptable_style_type?(attrs) do
    case attribute(attrs, "type") do
      nil -> true
      type -> MediaType.css?(type)
    end
  end

  defp skip_link?(attrs, opts) do
    opts[:respect_robots] != false and
      (page_nofollow?(opts) or "nofollow" in rel_tokens(attrs))
  end

  defp page_nofollow?(opts) do
    opts[:respect_robots] != false and opts[:robots_nofollow] == true
  end

  defp ascii_essence(type) do
    type
    |> String.split(";", parts: 2)
    |> hd()
    |> String.replace(~r/^[\t\n\f\r ]+|[\t\n\f\r ]+$/, "")
  end

  defp rel_tokens(attrs),
    do:
      attrs
      |> normalized("rel")
      |> String.split(~r/[\t\n\f\r ]+/, trim: true)

  defp normalized(attrs, name),
    do: attrs |> attribute(name) |> to_string() |> String.downcase(:ascii)
end
