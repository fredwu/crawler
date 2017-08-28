defmodule Crawler.Parser.LinkParser do
  @moduledoc """
  Parses links and transforms them if necessary.
  """

  alias __MODULE__.LinkExpander

  @tag_attr %{
    "a"      => "href",
    "link"   => "href",
    "script" => "src",
    "img"    => "src",
  }

  @doc """
  Parses links and transforms them if necessary.

  ## Examples

      iex> LinkParser.parse(
      iex>   {"a", [{"hello", "world"}, {"href", "http://hello.world"}], []},
      iex>   %{},
      iex>   &Kernel.inspect(&1, Enum.into(&2, []))
      iex> )
      "{\\\"href\\\", \\\"http://hello.world\\\"}"

      iex> LinkParser.parse(
      iex>   {"img", [{"hello", "world"}, {"src", "http://hello.world"}], []},
      iex>   %{},
      iex>   &Kernel.inspect(&1, Enum.into(&2, []))
      iex> )
      "{\\\"src\\\", \\\"http://hello.world\\\"}"
  """
  def parse({tag, attrs, _}, opts, link_handler) do
    src = @tag_attr[tag]

    with {_tag, link} <- detect_link(src, attrs),
         element      <- LinkExpander.expand({src, link}, opts)
    do
      opts = Map.merge(opts, %{html_tag: tag})

      link_handler.(element, opts)
    end
  end

  defp detect_link(src, attrs) do
    Enum.find(attrs, fn(attr) ->
      Kernel.match?({^src, _link}, attr)
    end)
  end
end
