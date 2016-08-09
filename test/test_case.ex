defmodule Crawler.TestCase do
  use ExUnit.CaseTemplate

  setup_all do
    bypass = Bypass.open()
    url    = "http://localhost:#{bypass.port}"

    {:ok, bypass: bypass, url: url}
  end
end
