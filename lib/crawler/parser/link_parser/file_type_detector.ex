defmodule Crawler.Parser.LinkParser.FileTypeDetector do
  @moduledoc """
  Detects the file type of a given link.
  """

  @doc """
  ## Examples

      iex> FileTypeDetector.detect("http://hello.world/page.html")
      "html"
  """
  def detect(link) do
    ~r{\.(\w+)$}
    |> Regex.run(link, capture: :all_but_first)
    |> return_file_type
  end

  defp return_file_type(nil),  do: ""
  defp return_file_type(list), do: Kernel.hd(list)
end
