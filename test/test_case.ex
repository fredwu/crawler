defmodule Crawler.TestCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Helpers
    end
  end

  setup_all do
    bypass  = Bypass.open
    url     = "http://localhost:#{bypass.port}"
    path    = "localhost-#{bypass.port}"

    bypass2 = Bypass.open
    url2    = "http://localhost:#{bypass2.port}"
    path2   = "localhost-#{bypass2.port}"

    {
      :ok,
      bypass:  bypass,  url: url,   path: path,
      bypass2: bypass2, url2: url2, path2: path2
    }
  end
end
