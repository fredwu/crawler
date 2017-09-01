defmodule Crawler.Parser.HtmlParser do
  @moduledoc """
  Parses HTML files.
  """

  @tag_selectors %{
    "pages"  => "a",
    "js"     => "script[type='text/javascript'][src]",
    "css"    => "link[rel='stylesheet']",
    "images" => "img",
  }

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
    Floki.find(body, selectors(opts))
  end

  defp selectors(opts) do
    @tag_selectors
    |> Map.take(["pages"] ++ (opts[:assets] || []))
    |> Map.values()
    |> Enum.join(", ")
  end
end
