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

  def import_map?(attrs) do
    case attribute(attrs, "type") do
      type when is_binary(type) ->
        trimmed = Regex.replace(~r/^[\t\n\f\r ]+|[\t\n\f\r ]+$/, type, "")
        String.downcase(trimmed, :ascii) == "importmap" and is_nil(attribute(attrs, "src"))

      _type ->
        false
    end
  end

  def speculation_rules?(attrs) do
    case attribute(attrs, "type") do
      type when is_binary(type) ->
        trimmed = Regex.replace(~r/^[\t\n\f\r ]+|[\t\n\f\r ]+$/, type, "")
        String.downcase(trimmed, :ascii) == "speculationrules"

      _type ->
        false
    end
  end

  def link_choice(attrs) do
    if attribute(attrs, "crawler-speculation-rules") != nil do
      choice("link", "link", :speculation_rules, false, :always)
    else
      classify(considered_rels(attrs), normalized(attrs, "as"))
    end
  end

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
    cond do
      speculation_rules?(attrs) and attribute(attrs, "src") != nil ->
        ["src"]

      enabled?(opts, "js") and script_source(attrs) == :external ->
        ["src"]

      true ->
        []
    end
  end

  defp element_attributes("link", attrs, opts, :html) do
    href =
      cond do
        document_links?(opts) -> ["href"]
        link_enabled?(attrs, opts) and not blocked_navigation?(attrs, opts) -> ["href"]
        true -> []
      end

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
    case link_choice(attrs) do
      :skip -> false
      %{channel: channel} -> channel_open?(channel, attrs, opts)
    end
  end

  defp link_role(attrs) do
    case link_choice(attrs) do
      %{html_tag: tag} -> tag
      :skip -> "link"
    end
  end

  defp classify(rels, as) do
    cond do
      "modulepreload" in rels ->
        choice("script", "link", nil, false, {:asset, "js"})

      "stylesheet" in rels ->
        choice("link", "link", nil, false, {:style, "css"})

      "preload" in rels and as == "style" ->
        choice("link", "link", nil, false, {:style, "css"})

      "preload" in rels and as == "font" ->
        choice("font", "link", nil, false, {:asset, "css"})

      "preload" in rels and as == "script" ->
        choice("script", "link", nil, false, {:asset, "js"})

      "preload" in rels and as == "image" ->
        choice("img", "link", nil, false, {:asset, "images"})

      # "link" is a parsable document tag. A fetch preload is only the response bytes.
      "preload" in rels and as == "fetch" ->
        choice("fetch", "link", nil, false, :any)

      "preload" in rels and as == "track" ->
        choice("track", "link", nil, false, {:track, "images"})

      icon_rel?(rels) ->
        choice("img", "link", nil, false, {:asset, "images"})

      "manifest" in rels ->
        choice("link", "link", :manifest, false, :always)

      "prefetch" in rels or "prerender" in rels ->
        choice("a", "a", nil, false, :always)

      "next" in rels or "prev" in rels or "previous" in rels ->
        choice("a", "a", nil, true, :always)

      true ->
        :skip
    end
  end

  defp choice(html_tag, reference_tag, fetch_kind, nofollow, channel) do
    %{
      html_tag: html_tag,
      reference_tag: reference_tag,
      fetch_kind: fetch_kind,
      nofollow: nofollow,
      channel: channel
    }
  end

  defp considered_rels(attrs) do
    rels = rel_tokens(attrs)
    rels = if disabled?(attrs), do: Enum.reject(rels, &(&1 == "stylesheet")), else: rels

    if from_header?(attrs),
      do: Enum.reject(rels, &(&1 in ["prefetch", "prerender", "manifest"])),
      else: rels
  end

  defp channel_open?(:always, _attrs, _opts), do: true

  defp channel_open?(:any, _attrs, opts) do
    enabled?(opts, "css") or enabled?(opts, "js") or enabled?(opts, "images")
  end

  defp channel_open?({:asset, channel}, _attrs, opts), do: enabled?(opts, channel)

  defp channel_open?({:style, channel}, attrs, opts) do
    enabled?(opts, channel) and acceptable_style_type?(attrs)
  end

  defp channel_open?({:track, channel}, attrs, opts) do
    enabled?(opts, channel) and acceptable_track_type?(attrs)
  end

  defp blocked_navigation?(attrs, opts) do
    case link_choice(attrs) do
      %{nofollow: true} -> skip_link?(attrs, opts)
      _choice -> false
    end
  end

  defp disabled?(attrs), do: attribute(attrs, "disabled") != nil
  defp from_header?(attrs), do: attribute(attrs, "crawler-from-header") != nil

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

  defp acceptable_track_type?(attrs) do
    case attribute(attrs, "type") do
      nil -> true
      "" -> true
      type -> type |> String.downcase(:ascii) |> ascii_essence() == "text/vtt"
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
