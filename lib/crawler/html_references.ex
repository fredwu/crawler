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
      classify(considered_rels(attrs), normalized(attrs, "as"), attrs)
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
    cond do
      "modulepreload" in rel_tokens(attrs) -> :module
      module_worklet?(attrs) -> :module
      true -> :script
    end
  end

  def credentials(tag, attr, attrs, namespace \\ :html)

  def credentials(_tag, attr, _attrs, :math) when attr in ["href", "xlink:href"], do: :include

  def credentials("link", attr, attrs, :html) when attr in ["href", "imagesrcset"] do
    link_credentials(link_choice(attrs), attrs)
  end

  def credentials("script", "src", attrs, _namespace), do: script_credentials(attrs)

  def credentials("script", attr, attrs, :svg) when attr in ["href", "xlink:href"] do
    script_credentials(attrs)
  end

  def credentials("script", "href", attrs, :html), do: keyword_credentials(attrs, :same_origin)

  def credentials(tag, _attr, attrs, _namespace)
      when tag in ["img", "source", "input", "video", "audio", "track"] do
    keyword_credentials(attrs, :include)
  end

  def credentials(tag, attr, attrs, :svg)
      when tag in @svg_paint and attr in ["href", "xlink:href"] do
    keyword_credentials(attrs, :include)
  end

  def credentials(_tag, _attr, _attrs, _namespace), do: :include

  def script_credentials(attrs) do
    cond do
      speculation_rules?(attrs) -> :include
      script_goal(attrs) == :module -> keyword_credentials(attrs, :same_origin)
      true -> keyword_credentials(attrs, :include)
    end
  end

  # Workers and worklets keep their own module map. The page import map stays
  # with ordinary scripts.
  def worker_entry?(attrs) do
    "preload" in rel_tokens(attrs) and worker_as?(normalized(attrs, "as"))
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
  def role("input", "src", attrs), do: if(image_button?(attrs), do: "img", else: "link")
  def role(tag, _attr, _attrs) when tag in ["img", "source", "video", "audio", "track"], do: tag
  def role(_tag, _attr, _attrs), do: "link"

  def integrity_resource?("script", attrs), do: script_source(attrs) == :external

  def integrity_resource?("link", attrs) do
    rel = rel_tokens(attrs)
    as = normalized(attrs, "as")

    Enum.any?(rel, &(&1 in ["stylesheet", "modulepreload"])) or
      ("preload" in rel and rewritten_preload?(as))
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

  defp element_attributes("input", attrs, opts, :html) do
    if image_button?(attrs), do: channel_attributes(opts, "images", ["src"]), else: []
  end

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

  defp classify(rels, as, attrs) do
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

      "preload" in rels and as in ["audio", "video"] ->
        choice(as, "link", nil, false, {:asset, "images"})

      "preload" in rels and as == "document" ->
        choice("a", "a", nil, false, :always)

      "preload" in rels and worker_as?(as) ->
        choice("script", "link", nil, false, {:asset, "js"})

      icon_rel?(rels) ->
        choice("img", "link", nil, false, {:asset, "images"})

      "manifest" in rels ->
        choice("link", "link", :manifest, false, :always)

      "prerender" in rels ->
        choice("a", "a", nil, false, :always)

      "prefetch" in rels ->
        Map.put(choice("a", "a", nil, false, :always), :page_open, false)

      "next" in rels or "prev" in rels or "previous" in rels ->
        choice("a", "a", nil, true, :always)

      feed_alternate?(rels, attrs) ->
        choice("a", "a", :feed, true, :always)

      true ->
        :skip
    end
  end

  # A stylesheet that is also alternate stays a stylesheet. Language alternates
  # have no feed type, so they stay unfetched.
  defp feed_alternate?(rels, attrs) do
    "alternate" in rels and "stylesheet" not in rels and MediaType.feed?(attribute(attrs, "type"))
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

  defp link_credentials(%{html_tag: "font"}, _attrs), do: :same_origin

  defp link_credentials(%{html_tag: "script"}, attrs) do
    keyword_credentials(attrs, script_link_default(attrs))
  end

  defp link_credentials(%{html_tag: "a", page_open: false}, attrs) do
    keyword_credentials(attrs, :include)
  end

  defp link_credentials(%{html_tag: "a"}, _attrs), do: :include
  defp link_credentials(_choice, attrs), do: keyword_credentials(attrs, :include)

  defp script_link_default(attrs) do
    cond do
      "modulepreload" in rel_tokens(attrs) -> :same_origin
      worker_as?(normalized(attrs, "as")) -> :same_origin
      true -> :include
    end
  end

  # A missing attribute keeps the element's default. `use-credentials` sends
  # cookies. Any other present value, including empty, is anonymous.
  defp keyword_credentials(attrs, missing) do
    case crossorigin_keyword(attribute(attrs, "crossorigin")) do
      :missing -> missing
      "use-credentials" -> :include
      _other -> :same_origin
    end
  end

  defp crossorigin_keyword(nil), do: :missing

  defp crossorigin_keyword(value) when is_binary(value) do
    value |> String.trim() |> String.downcase(:ascii)
  end

  defp crossorigin_keyword(_value), do: :missing

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

  defp icon_rel?(rel) do
    Enum.any?(
      rel,
      &(&1 in [
          "icon",
          "apple-touch-icon",
          "apple-touch-icon-precomposed",
          "apple-touch-startup-image",
          "mask-icon"
        ])
    )
  end

  defp image_button?(attrs), do: normalized(attrs, "type") == "image"

  defp module_worklet?(attrs) do
    "preload" in rel_tokens(attrs) and normalized(attrs, "as") in ["paintworklet", "audioworklet"]
  end

  defp worker_as?(as) do
    as in ["worker", "serviceworker", "sharedworker", "paintworklet", "audioworklet"]
  end

  # The saved worker, worklet, or document no longer matches its original hash.
  # Audio, video, and fetch bytes stay intact, so their hashes stay too.
  defp rewritten_preload?(as) do
    as in ["script", "style", "document"] or worker_as?(as)
  end

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
