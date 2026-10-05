defmodule Crawler.SiteTest do
  use ExUnit.Case, async: true

  alias Crawler.Site

  test "www and the default http and https ports are one site" do
    assert Site.same_site?("http://example.com/a", "https://www.example.com/b")
    assert Site.same_site?("https://Example.com", "http://example.com:80/c")
    assert Site.same_site?("http://WWW.example.com", "https://example.com:443")
  end

  test "another host, an extra www label, or another port is a different site" do
    refute Site.same_site?("http://example.com", "http://blog.example.com")
    refute Site.same_site?("http://www.www.example.com", "http://example.com")
    refute Site.same_site?("http://localhost:4000/a", "http://localhost:4001/a")
    refute Site.same_site?("http://example.com", "not a url")
    refute Site.same_site?(nil, "http://example.com")
    refute Site.same_site?("http://example.com/", "http://example.com:443/admin")
    refute Site.same_site?("https://example.com/", "https://example.com:80/admin")
    refute Site.same_site?("http://example.com:443/", "https://example.com:80/")
    refute Site.same_site?("http://example.com:8080/", "https://example.com/")
    assert Site.same_site?("http://example.com:8080/a", "https://example.com:8080/b")
  end

  test "a local host and port stay one site" do
    assert Site.same_site?("http://localhost:4000/a", "http://localhost:4000/b")
    assert Site.same_site?("http://127.0.0.1/a", "http://127.0.0.1/b")
  end

  test "robots origins keep www and omit default ports" do
    assert Site.origin("https://www.example.com/a") == "https://www.example.com"
    assert Site.origin("http://example.com:80/a") == "http://example.com"
    assert Site.origin("http://localhost:4000/a") == "http://localhost:4000"
    assert Site.origin("https://example.com:444/a") == "https://example.com:444"
    assert Site.origin("not a url") == nil
    assert Site.origin("http://[::1]/a") == "http://[::1]"
    assert Site.origin("http://[FE80::1]:4000/a") == "http://[fe80::1]:4000"
  end
end
