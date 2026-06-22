defmodule Crawler.TestCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Crawler.TestHelpers
      alias Crawler.ReqTestSite
    end
  end

  setup do
    {:ok, Crawler.ReqTestSite.open(hosts: 2)}
  end
end
