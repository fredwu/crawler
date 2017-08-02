defmodule Crawler.TestCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Helpers
    end
  end

  setup_all do
    on_exit fn ->
      [File.cwd!, "test", "tmp", "*"]
      |> Path.join
      |> Path.wildcard
      |> Enum.each(&File.rm_rf/1)
    end

    bypass = Bypass.open
    url    = "http://localhost:#{bypass.port}"

    {:ok, bypass: bypass, url: url}
  end
end
