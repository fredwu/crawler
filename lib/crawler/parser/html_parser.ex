defmodule Crawler.Parser.HtmlParser do
  @moduledoc """
  Parses HTML files.
  """

  @asset_tags %{
    "pages"  => "a",
    "js"     => "script[type='text/javascript']",
    "css"    => "link[rel='stylesheet']",
    "images" => "img",
  }

  @doc """
  ## Examples

      iex> HtmlParser.parse(
      iex>   "<a href='http://hello.world'>Link</a>",
      iex>   %{}
      iex> )
      [{"a", [{"href", "http://hello.world"}], ["Link"]}]
  """
  def parse(body, opts) do
    Floki.find(body, tags(opts))
  end

  defp tags(opts) do
    @asset_tags
    |> Map.take(["pages"] ++ (opts[:assets] || []))
    |> Map.values
    |> Enum.join(", ")
  end
end
