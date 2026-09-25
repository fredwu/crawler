defmodule Crawler.Linker.PathOffliner do
  @moduledoc """
  Transforms a link to be storable and linkable offline.
  """

  alias Crawler.Linker.PathFinder

  @query_marker "__q_"

  @doc """
  Transforms a given link so that it can be stored and linked to by other pages.

  When a page does not have a file extension (e.g. html) it is treated as the
  index page for a directory, therefore `__index.html` is appended to the link.
  A URL that already ends in `index.html` keeps that filename.

  A query string is folded into the file name, without `?` or `&`.

  ## Examples

      iex> PathOffliner.transform("http://hello.world")
      "http://hello.world/__index.html"

      iex> PathOffliner.transform("hello.world")
      "hello.world/__index.html"

      iex> PathOffliner.transform("hello.world/")
      "hello.world/__index.html"

      iex> PathOffliner.transform("hello/world")
      "hello/world/__index.html"

      iex> PathOffliner.transform("hello/world.html")
      "hello/world.html"

      iex> PathOffliner.transform("http://host/foo/index.html")
      "http://host/foo/index.html"

      iex> PathOffliner.transform("http://host/search?q=1&x=2")
      "http://host/search/__index__q_q=1%26x=2.html"

      iex> PathOffliner.transform("http://host/search?q=2")
      "http://host/search/__index__q_q=2.html"

      iex> PathOffliner.transform("http://host/search?q=1&x=2") ==
      iex>   PathOffliner.transform("http://host/search?q=1--x=2")
      false

      iex> PathOffliner.transform("http://host/app.js?v=1") ==
      iex>   PathOffliner.transform("http://host/app__q_v=1.js")
      false

      iex> PathOffliner.transform("http://host/search?q=1&x=2") ==
      iex>   PathOffliner.transform("http://host/search/__index.html?q=1&x=2")
      false
  """
  def transform(link) do
    {bare, query} = split_query(link)

    bare
    |> directory_index()
    |> escape_reserved(bare)
    |> attach_query(query)
  end

  defp split_query(link) do
    case String.split(link, "?", parts: 2) do
      [bare, query] when query != "" -> {bare, query}
      [bare | _] -> {bare, nil}
    end
  end

  defp directory_index(link) do
    link
    |> PathFinder.find_path()
    |> String.split("/", trim: true)
    |> Enum.count()
    |> last_segment(link)
  end

  defp last_segment(1, link) do
    append_index(false, link)
  end

  defp last_segment(_count, link) do
    link
    |> String.split("/")
    |> Enum.take(-1)
    |> Kernel.hd()
    |> has_extension()
    |> append_index(link)
  end

  defp has_extension(segment), do: String.contains?(segment, ".")

  defp append_index(true, link), do: link
  defp append_index(false, link), do: Path.join(link, "__index.html")

  defp escape_reserved(offline, original) do
    offline
    |> String.replace("%", "%25")
    |> String.replace(@query_marker, "__q%5F")
    |> escape_literal_index(original)
  end

  defp escape_literal_index(offline, original) do
    if original |> String.split("/") |> List.last() == "__index.html" do
      String.replace_suffix(offline, "__index.html", "__index%2Ehtml")
    else
      offline
    end
  end

  defp attach_query(offline, nil), do: offline

  defp attach_query(offline, query) do
    token = @query_marker <> encode_query(query)
    ext = Path.extname(offline)

    if ext == "" do
      offline <> token
    else
      String.replace_suffix(offline, ext, token <> ext)
    end
  end

  defp encode_query(query) do
    query
    |> String.replace("%", "%25")
    |> String.replace(~r/[^A-Za-z0-9._=-]/, fn char ->
      "%" <> Base.encode16(char, case: :lower)
    end)
  end
end
