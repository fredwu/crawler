defmodule Crawler.Options do
  @max_levels 3

  @doc """
  ## Examples

      iex> Options.assign_defaults([]) |> Keyword.has_key?(:level)
      true

      iex> Options.assign_defaults([]) |> Keyword.get(:max_levels)
      3

      iex> Options.assign_defaults([max_levels: 4]) |> Keyword.get(:max_levels)
      4
  """
  def assign_defaults(opts) do
    Keyword.merge([
      level:      0,
      max_levels: max_levels(),
    ], opts)
  end

  @doc """
  ## Examples

      iex> Options.assign_url([], "http://localhost/")
      [url: "http://localhost/"]

      iex> Options.assign_url([url: "http://example.com/"], "http://localhost/")
      [url: "http://localhost/"]
  """
  def assign_url(opts, url) do
    Keyword.merge(opts, [url: url])
  end

  defp max_levels, do: Application.get_env(:crawler, :max_levels) || @max_levels
end
