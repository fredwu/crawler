defmodule Crawler.Parser.LinkParser do
  @moduledoc """
  Parses links and transforms them if necessary.
  """

  alias Crawler.Linker

  @tag_attr %{
    "a"    => "href",
    "link" => "href",
    "img"  => "src",
  }

  @doc """
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
         element      <- expand_link_into_url({src, link}, opts)
    do
      link_handler.(element, Map.merge(opts, %{html_tag: tag}))
    end
  end

  defp detect_link(src, attrs) do
    Enum.find(attrs, fn(attr) ->
      Kernel.match?({^src, _link}, attr)
    end)
  end

  defp expand_link_into_url(element = {_tag, link}, opts) do
    link
    |> is_url?
    |> transform_link(element, opts)
  end

  defp is_url?(link), do: String.contains?(link, "://")

  defp transform_link(true, element, _opts), do: element

  defp transform_link(false, {tag, link}, opts) do
    {"link", link, @tag_attr[tag], Linker.url(opts[:referrer_url], link)}
  end
end
