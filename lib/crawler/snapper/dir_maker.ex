defmodule Crawler.Snapper.DirMaker do
  @moduledoc """
  Makes a new (nested) folder according to the options provided.
  """

  alias Crawler.{Linker, Linker.PathFinder}

  @doc """
  Makes a new (nested) folder according to the options provided.

  ## Examples

      iex> DirMaker.make_dir(
      iex>   save_to: tmp("snapper/dir_creator"),
      iex>   url: "http://hello-world.local"
      iex> )
      iex> |> Path.relative_to_cwd
      "test/tmp/snapper/dir_creator/hello-world.local/index.html"
  """
  def make_dir(opts) do
    opts[:url]
    |> prep_filepath()
    |> build_save_path(opts[:save_to])
    |> make_save_path(opts[:save_to])
  end

  defp prep_filepath(url) do
    url
    |> Linker.offline_url(url)
    |> PathFinder.find_path()
  end

  defp build_save_path(path, save_to) do
    Path.join(save_to, path)
  end

  defp make_save_path(path, save_to) do
    if File.exists?(save_to) do
      File.mkdir_p(Path.dirname(path))
    end

    path
  end
end
