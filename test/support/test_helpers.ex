defmodule Crawler.TestHelpers do
  import ExUnit.Assertions, only: [refute: 1]

  def start_crawl(url, opts \\ []) do
    result = Crawler.crawl(url, opts)

    case result do
      {:ok, crawl} ->
        owned_queue? = is_nil(Enum.into(opts, %{})[:queue])

        case Crawler.ReqTestSite.track_crawl(crawl, owned_queue?: owned_queue?) do
          :ok -> result
          {:error, _} = error -> error
        end

      _ ->
        result
    end
  end

  def wait(fun), do: wait(500, fun)

  def wait(timeout, fun) when is_integer(timeout) and timeout >= 0 do
    wait_until(System.monotonic_time(:millisecond) + timeout, fun)
  end

  defp wait_until(deadline, fun) do
    fun.()
  rescue
    error in ExUnit.AssertionError ->
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        reraise error, __STACKTRACE__
      end

      receive do
      after
        min(10, remaining) -> wait_until(deadline, fun)
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
