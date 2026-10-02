defmodule Crawler.Snapper.LinkReplacer.RawText do
  @moduledoc false

  alias Crawler.MediaType
  alias Crawler.Snapper.LinkReplacer.Javascript

  @tag_contents ~S{(?:[^>"']|"[^"]*"|'[^']*')*}
  @markup Regex.compile!("<!--.*?(?:-->|$)|<(?=[!?]|/?[A-Za-z])#{@tag_contents}>", "s")
  @text_elements ~w(script style textarea title xmp iframe noembed noframes plaintext)
  @raw_opening Regex.compile!(
                 "^<(#{Enum.join(@text_elements, "|")})(?=[\\t\\n\\f\\r />])(.*)>$",
                 "is"
               )

  def protect(body, opts) do
    if MediaType.css?(opts[:content_type]) or MediaType.javascript?(opts[:content_type]) do
      {body, []}
    else
      body
      |> regions(0, [])
      |> Enum.with_index()
      |> Enum.reduce({body, []}, &protect_region(&1, &2, opts))
    end
  end

  def restore(body, saved, rewrite) do
    Enum.reduce(saved, body, fn {token, source, type}, body ->
      source = if type, do: rewrite.(source, type), else: source
      String.replace(body, token, source)
    end)
  end

  defp regions(body, offset, acc) do
    case Regex.run(@markup, body, return: :index) do
      [{start, length}] ->
        tag = binary_part(body, start, length)
        consumed = start + length
        scan_tag(tag, remaining(body, consumed), offset + consumed, acc)

      nil ->
        acc
    end
  end

  defp scan_tag(tag, body, offset, acc) do
    case Regex.run(@raw_opening, tag, capture: :all_but_first) do
      [name, attrs] ->
        name = String.downcase(name)
        {length, consumed} = raw_end(body, name)
        region = {offset, length, name, attrs}
        regions(remaining(body, consumed), offset + consumed, [region | acc])

      nil ->
        regions(body, offset, acc)
    end
  end

  defp raw_end(body, "plaintext"), do: {byte_size(body), byte_size(body)}

  defp raw_end(body, name) do
    case Regex.run(~r/<\/#{name}(?=[\t\n\f\r \/>])#{@tag_contents}>/is, body, return: :index) do
      [{start, length}] -> {start, start + length}
      nil -> {byte_size(body), byte_size(body)}
    end
  end

  defp remaining(body, consumed), do: binary_part(body, consumed, byte_size(body) - consumed)

  defp protect_region({{start, length, name, attrs}, index}, {body, saved}, opts) do
    source = binary_part(body, start, length)
    type = content_type(name, attrs, opts)
    token = <<0>> <> "R#{index}" <> <<0>>
    head = binary_part(body, 0, start)
    tail = binary_part(body, start + length, byte_size(body) - start - length)

    {head <> token <> tail, [{token, source, type} | saved]}
  end

  defp content_type(tag, attrs, opts) do
    cond do
      tag == "style" and "css" in List.wrap(opts[:assets]) ->
        "text/css"

      tag == "script" and "js" in List.wrap(opts[:assets]) and
          Javascript.source?(attrs) ->
        "application/javascript"

      true ->
        nil
    end
  end
end
