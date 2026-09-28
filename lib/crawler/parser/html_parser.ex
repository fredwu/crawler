defmodule Crawler.Parser.HtmlParser do
  @moduledoc """
  Parses HTML files.
  """

  @doc """
  Parses HTML files.

  ## Examples

      iex> HtmlParser.parse(
      iex>   "<a href='http://hello.world'>Link</a>",
      iex>   %{}
      iex> )
      [{"a", [{"href", "http://hello.world"}], ["Link"]}]

      iex> HtmlParser.parse(
      iex>   "<script type='text/javascript'>js</script>",
      iex>   %{assets: ["js"]}
      iex> )
      []
  """
  def parse(body, opts) do
    {:ok, document} = Floki.parse_document(body)
    assets = opts[:assets] || []

    document
    |> Floki.find("a, area, iframe")
    |> include(assets, "js", fn -> js_nodes(document) end)
    |> include(assets, "images", fn -> image_nodes(document) end)
    |> include(assets, "css", fn -> css_nodes(document) end)
    |> Enum.uniq()
  end

  defp include(nodes, assets, asset, fun) do
    if asset in assets, do: nodes ++ fun.(), else: nodes
  end

  defp js_nodes(document) do
    Floki.find(document, "script[src]") ++ preload_links(document, "script")
  end

  defp image_nodes(document) do
    Floki.find(document, "img, source, video, audio, track, image, use") ++
      icon_links(document) ++
      preload_links(document, "image")
  end

  defp css_nodes(document) do
    stylesheets = document |> Floki.find("link[href]") |> Enum.filter(&stylesheet?/1)

    stylesheets ++ Floki.find(document, "style") ++ Floki.find(document, "[style]")
  end

  defp icon_links(document) do
    document
    |> Floki.find("link[href]")
    |> Enum.filter(&icon?/1)
  end

  defp preload_links(document, as) do
    document
    |> Floki.find("link[href]")
    |> Enum.filter(&preload?(&1, as))
  end

  defp stylesheet?({_tag, attrs, _children}) do
    rel = rel_tokens(attrs)
    as = attrs |> attribute("as") |> String.downcase()

    "stylesheet" in rel or ("preload" in rel and as in ["style", "font"])
  end

  defp icon?({_tag, attrs, _children}) do
    rel = rel_tokens(attrs)

    "icon" in rel or "apple-touch-icon" in rel or "mask-icon" in rel
  end

  defp preload?({_tag, attrs, _children}, as) do
    rel = rel_tokens(attrs)
    value = attrs |> attribute("as") |> String.downcase()

    "preload" in rel and value == as
  end

  defp rel_tokens(attrs) do
    attrs
    |> attribute("rel")
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
  end

  defp attribute(attrs, name) do
    Enum.find_value(attrs, "", fn
      {^name, value} -> value
      _ -> nil
    end)
  end
end
