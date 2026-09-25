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
    |> Floki.find("a")
    |> include(assets, "js", fn -> Floki.find(document, "script[src]") end)
    |> include(assets, "images", fn -> Floki.find(document, "img, source, video, audio") end)
    |> include(assets, "css", fn -> css_nodes(document) end)
    |> Enum.uniq()
  end

  defp include(nodes, assets, asset, fun) do
    if asset in assets, do: nodes ++ fun.(), else: nodes
  end

  defp css_nodes(document) do
    stylesheets = document |> Floki.find("link[href]") |> Enum.filter(&stylesheet?/1)

    stylesheets ++ Floki.find(document, "style") ++ Floki.find(document, "[style]")
  end

  defp stylesheet?({_tag, attrs, _children}) do
    rel = attrs |> attribute("rel") |> String.downcase() |> String.split(~r/\s+/, trim: true)
    as = attrs |> attribute("as") |> String.downcase()

    "stylesheet" in rel or ("preload" in rel and as == "style")
  end

  defp attribute(attrs, name) do
    Enum.find_value(attrs, "", fn
      {^name, value} -> value
      _ -> nil
    end)
  end
end
