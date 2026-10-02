defmodule Crawler.Snapper.LinkReplacer.Html do
  @moduledoc false

  alias Crawler.MediaType
  alias Crawler.Parser.Srcset
  alias Crawler.Snapper.LinkReplacer.Css
  alias Crawler.Snapper.LinkReplacer.QuotedLink

  @attribute ~r/\s+([^\s"'<>\/=]+)(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?/s

  def drop_base(body, opts) do
    if html_document?(opts) do
      String.replace(
        body,
        ~r/<\s*\/?\s*base\b(?:[^>"']|"(?:\\.|[^"])*"|'(?:\\.|[^'])*')*>/i,
        ""
      )
    else
      body
    end
  end

  defp html_document?(opts), do: MediaType.html?(opts[:content_type])

  def drop_rewritten_integrity(body, tokens, opts) do
    if html_document?(opts) do
      tokens = MapSet.new(tokens)
      replace_in_tags(body, &drop_tag_integrity(&1, tokens))
    else
      body
    end
  end

  defp drop_tag_integrity(tag, tokens) do
    if rewritten_resource?(tag, tokens) do
      Regex.replace(@attribute, tag, &keep_unless_integrity/2)
    else
      tag
    end
  end

  defp keep_unless_integrity(attribute, name) do
    if String.downcase(name) == "integrity", do: "", else: attribute
  end

  defp rewritten_resource?(tag, tokens) do
    with true <- Regex.match?(~r/^<(script|link)(?=[\s\/>])/i, tag),
         {:ok, [{name, attrs, _children}]} <- Floki.parse_fragment(tag) do
      MapSet.member?(tokens, resource_url(name, attrs))
    else
      _ -> false
    end
  end

  defp resource_url("script", attrs), do: attribute(attrs, "src")

  defp resource_url("link", attrs) do
    rel = attrs |> attribute("rel") |> to_string() |> String.downcase() |> String.split()
    if Enum.any?(rel, &(&1 in ["stylesheet", "modulepreload"])), do: attribute(attrs, "href")
  end

  defp attribute(attrs, name) do
    Enum.find_value(attrs, fn {key, value} -> if key == name, do: value end)
  end

  def replace_style_attributes(body, variant, offline) do
    replace_in_tags(body, &replace_tag_style_attributes(&1, variant, offline))
  end

  defp replace_tag_style_attributes(tag, variant, offline) do
    Regex.replace(
      ~r/([^\s"'<>\/=]+)(\s*=\s*)(?:(["'])(.*?)\3|([^\s"'=<>`]+))/s,
      tag,
      fn attribute, name, separator, quote, quoted_value, unquoted_value ->
        value = if quote == "", do: unquoted_value, else: quoted_value

        if String.downcase(name) == "style" do
          name <> separator <> quote <> Css.replace(value, variant, offline) <> quote
        else
          attribute
        end
      end
    )
  end

  def replace_srcset(body, variant, offline) do
    replace_in_tags(body, fn tag ->
      Regex.replace(
        ~r/((?<![\w-])(?i:imagesrcset|srcset)\s*=\s*)(["'])([^"']*)\2/,
        tag,
        fn _, attr, quote, value ->
          attr <> quote <> Srcset.replace(value, variant, offline) <> quote
        end
      )
    end)
  end

  defp replace_once(body, from, to) when from == to or from == "", do: body
  defp replace_once(body, from, to), do: String.replace(body, from, to, global: false)

  def replace_meta(body, variant, offline) do
    Enum.reduce(meta_tags(body), body, fn tag, body ->
      replace_once(body, tag, replace_meta_urls(tag, variant, offline))
    end)
  end

  defp meta_tags(body) do
    ~r/<\s*meta\b(?:[^>"']|"(?:\\.|[^"])*"|'(?:\\.|[^'])*')*>/i
    |> Regex.scan(body)
    |> Enum.map(&hd/1)
  end

  defp replace_meta_urls(tag, variant, offline) do
    tag
    |> QuotedLink.replace(variant, offline, prefix: "\\b(?i:url)\\s*=\\s*")
    |> then(fn tag ->
      Regex.replace(
        ~r/(\b(?i:url)\s*=\s*)(?!["'&])#{Regex.escape(variant)}(?=[\s;"'>]|$)/,
        tag,
        fn _, url -> url <> offline end
      )
    end)
  end

  def replace_attributes(body, variant, offline) do
    escaped = Regex.escape(variant)

    replace_in_tags(body, fn tag ->
      Regex.replace(
        ~r/((?<![\w-])(?i:href|src|poster|data)\s*=\s*)(["'])#{escaped}\2/,
        tag,
        fn _, attr, quote ->
          attr <> quote <> offline <> quote
        end
      )
    end)
  end

  def replace_unquoted(body, variant, offline) do
    body
    |> replace_unquoted_srcset(variant, offline)
    |> replace_unquoted_value(variant, offline)
  end

  defp replace_unquoted_srcset(body, variant, offline) do
    replace_in_tags(body, fn tag ->
      Regex.replace(
        ~r/((?<![\w-])(?i:imagesrcset|srcset)\s*=\s*)(?!["'])(.+?)(?=[\s>]|\/(?=>)|$)/,
        tag,
        fn _, attr, value ->
          attr <> Srcset.replace(value, variant, offline)
        end
      )
    end)
  end

  defp replace_unquoted_value(body, variant, offline) do
    escaped = Regex.escape(variant)

    replace_in_tags(body, fn tag ->
      Regex.replace(
        # A slash is part of a relative path. Only `/>` ends the tag.
        ~r/((?<![\w-])(?i:href|src|poster|data)\s*=\s*)(?!["'])#{escaped}(?=[\s>]|\/(?=>)|$)/,
        tag,
        fn _, attr -> attr <> offline end
      )
    end)
  end

  defp replace_in_tags(body, fun) do
    Regex.replace(~r/<[^>"']*(?:"[^"]*"|'[^']*'|[^>"'])*>/s, body, fn tag ->
      if String.starts_with?(tag, "<!"), do: tag, else: fun.(tag)
    end)
  end
end
