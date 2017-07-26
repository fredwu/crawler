defmodule Crawler.TestCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Helpers
    end
  end

  setup_all do
    bypass = Bypass.open()
    url    = "http://localhost:#{bypass.port}"

    {:ok, bypass: bypass, url: url}
  end
end
