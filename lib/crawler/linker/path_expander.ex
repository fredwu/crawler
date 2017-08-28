defmodule Crawler.Linker.PathExpander do
  @moduledoc """
  Expands the path by expanding any `.` and `..` characters.

  See [this pull request](https://github.com/elixir-lang/elixir/pull/6486).
  """

  @doc """
  Expands the path by expanding any `.` and `..` characters.

  Note this function only expands any `.` and `..` characters within the given
  path, and it does not take into account the absolute or relative nature of
  the path itself, for that please use `expand/1` or `expand/2`.

  ## Examples

      ### Intended use case

      iex> PathExpander.expand_dot("foo/bar/../baz")
      "foo/baz"

      iex> PathExpander.expand_dot("/foo/bar/../baz")
      "/foo/baz"

      ### Non-intended use cases are ignored

      iex> PathExpander.expand_dot("foo/bar/./baz")
      "foo/bar/baz"

      iex> PathExpander.expand_dot("../foo/bar")
      "foo/bar"
  """
  def expand_dot(<<"/", rest::binary>>),
    do: "/" <> do_expand_dot(rest)
  def expand_dot(path),
    do: do_expand_dot(path)

  defp do_expand_dot(path),
    do: do_expand_dot(:binary.split(path, "/", [:global]), [])
  defp do_expand_dot([".." | t], [_, _ | acc]),
    do: do_expand_dot(t, acc)
  defp do_expand_dot([".." | t], []),
    do: do_expand_dot(t, [])
  defp do_expand_dot(["." | t], acc),
    do: do_expand_dot(t, acc)
  defp do_expand_dot([h | t], acc),
    do: do_expand_dot(t, ["/", h | acc])
  defp do_expand_dot([], []),
    do: ""
  defp do_expand_dot([], ["/" | acc]),
    do: IO.iodata_to_binary(:lists.reverse(acc))
end
