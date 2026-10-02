# Credit: https://gist.github.com/cblavier/5e15791387a6e22b98d8
defmodule Crawler.TestHelpers do
  import ExUnit.Assertions, only: [refute: 1]

  def start_crawl(url, opts \\ []) do
    result = Crawler.crawl(url, opts)

    case result do
      {:ok, crawl} -> Crawler.ReqTestSite.track_crawl(crawl)
      _ -> :ok
    end

    result
  end

  def wait(fun), do: wait(500, fun)
  def wait(0, fun), do: fun.()

  def wait(timeout, fun) do
    try do
      fun.()
    rescue
      _ ->
        :timer.sleep(10)
        wait(max(0, timeout - 10), fun)
    end
  end

  def tmp(path \\ "", filename \\ "") do
    tmp_path = Path.join([File.cwd!(), "test", "tmp", path])

    File.mkdir_p(tmp_path)

    Path.join(tmp_path, filename)
  end

  def await_idle(opts) do
    wait(fn -> refute Crawler.running?(opts) end)
  end

  def unique_scope(name), do: "#{name}-#{System.unique_integer([:positive])}"

  def image_file do
    {:ok, file} = File.read("test/fixtures/introducing-elixir.jpg")
    file
  end
end
