defmodule Crawler.Fetcher.Snapper do
  @doc """
  ## Examples

      iex> Snapper.snap("hello", save_to: tmp("snapper"), url: "http://snapper/index.html")
      iex> File.read(tmp("snapper", "index.html"))
      {:ok, "hello"}

      iex> Snapper.snap("hello", save_to: "nope", url: "http://snapper/index.html")
      {:error, "Cannot write to file nope/index.html, reason: enoent"}
  """
  def snap(body, opts) do
    file_path = Path.join(opts[:save_to], filename(opts[:url]))

    case File.write(file_path, body) do
      :ok              -> {:ok, opts}
      {:error, reason} -> {:error, "Cannot write to file #{file_path}, reason: #{reason}"}
    end
  end

  defp filename(url) do
    Path.basename(url)
  end
end
