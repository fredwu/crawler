defmodule Crawler.Example.GoogleSearch.UrlFilterTest do
  use ExUnit.Case, async: true

  alias Crawler.Example.GoogleSearch.UrlFilter
  alias Crawler.URL

  test "allows only the approved HTTPS hosts with canonical spelling and explicit ports" do
    for url <- [
          "https://www.google.com/search?q=github",
          "https://github.com/fredwu/crawler?tab=readme#readme",
          "HTTPS://GITHUB.COM/fredwu/crawler",
          "https://WWW.GOOGLE.COM./search",
          "https://github.com./fredwu/crawler",
          "https://github.com:443/fredwu/crawler",
          "https://www.google.com:8443/search",
          "https://github.com:8443/fredwu/crawler"
        ] do
      assert UrlFilter.filter(url, %{}) == {:ok, true}
      assert UrlFilter.filter(URL.normalize(url), %{}) == {:ok, true}
    end
  end

  test "rejects deceptive hosts, credentials, other schemes and malformed references" do
    for url <- [
          "https://github.com.evil.test/project",
          "https://www.google.com.evil.test/search",
          "https://github.computer/project",
          "https://github.com@evil.test/project",
          "https://evil.test@github.com/project",
          "https://www.google.com@evil.test/search",
          "https://user:password@www.google.com/search",
          "https://github.com../project",
          "https://www.google.com../search",
          "https://api.github.com/project",
          "https://google.com/search",
          "http://github.com/project",
          "ftp://github.com/project",
          "https://github.com:invalid/project",
          "//github.com/project",
          "/github.com/project",
          "",
          nil
        ] do
      assert UrlFilter.filter(url, %{}) == {:ok, false}, inspect(url)
    end
  end
end
