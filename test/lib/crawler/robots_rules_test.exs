defmodule Crawler.RobotsRulesTest do
  use ExUnit.Case, async: true

  alias Crawler.Robots

  @star """
  User-agent: *
  Disallow: /secret
  Allow: /docs/public
  Disallow: /docs
  """

  @specific """
  User-agent: *
  Disallow: /secret

  User-agent: Googlebot
  Disallow: /

  User-agent: Crawler
  Disallow: /hidden
  Allow: /docs/public
  """

  test "the product token is the first token before a slash or space" do
    assert Robots.product_token("Crawler/1.5.0 (https://github.com/fredwu/crawler)") == "Crawler"
    assert Robots.product_token("  crawlerbot/1 ") == "crawlerbot"
    assert Robots.product_token(nil) == "Crawler"
  end

  test "star rules allow the longest match and an equal Allow wins" do
    rules = Robots.parse(@star)

    refute Robots.allowed?(rules, "http://example.com/secret", "Crawler/1")
    refute Robots.allowed?(rules, "http://example.com/docs/private", "Crawler/1")
    assert Robots.allowed?(rules, "http://example.com/docs/public", "Crawler/1")
    assert Robots.allowed?(rules, "http://example.com/other", "Crawler/1")

    assert Robots.allowed?(
             Robots.parse("User-agent: *\nDisallow: /file\nAllow: /file\n"),
             "http://example.com/file",
             "Crawler/1"
           )
  end

  test "a matching product group replaces star and ignores other agents" do
    rules = Robots.parse(@specific)

    refute Robots.allowed?(rules, "http://example.com/hidden", "Crawler/1.5.0")
    assert Robots.allowed?(rules, "http://example.com/secret", "Crawler/1.5.0")
    assert Robots.allowed?(rules, "http://example.com/docs/public", "Crawler/1.5.0")
    refute Robots.allowed?(rules, "http://example.com/anywhere", "Googlebot/2.1")
    refute Robots.allowed?(rules, "http://example.com/secret", "CrawlerBot/1")
  end

  test "a failed robots fetch disallows every path" do
    refute Robots.allowed?(Robots.disallow_all(), "http://example.com/docs", "Crawler/1")
  end

  test "an empty disallow allows the site and a missing file allows every path" do
    assert Robots.allowed?(
             Robots.parse("User-agent: *\nDisallow:\n"),
             "http://example.com/secret",
             "Crawler/1"
           )

    assert Robots.allowed?(Robots.parse(""), "http://example.com/secret", "Crawler/1")

    refute Robots.allowed?(
             Robots.parse("User-agent: *\nDisallow: /\n"),
             "http://example.com/docs",
             "Crawler/1"
           )
  end

  test "wildcards, end anchors, and query patterns compare the request target" do
    rules =
      Robots.parse("""
      User-agent: *
      Disallow: /*.pdf$
      Allow: /docs/public.pdf
      Disallow: /search?q=1
      """)

    refute Robots.allowed?(rules, "http://example.com/file.pdf", "Crawler/1")
    assert Robots.allowed?(rules, "http://example.com/file.pdfx", "Crawler/1")
    assert Robots.allowed?(rules, "http://example.com/docs/public.pdf", "Crawler/1")
    refute Robots.allowed?(rules, "http://example.com/search?q=1", "Crawler/1")
    assert Robots.allowed?(rules, "http://example.com/search?q=2", "Crawler/1")
    assert Robots.allowed?(rules, "http://example.com/search", "Crawler/1")
  end

  test "blank lines and comment lines stay inside the group" do
    rules =
      Robots.parse("""
      User-agent: *

      # keep this rule
      Disallow: /secret

      User-agent: Crawler
      Allow: /secret
      """)

    refute Robots.allowed?(rules, "http://example.com/secret", "Other/1")
    assert Robots.allowed?(rules, "http://example.com/secret", "Crawler/1")
  end

  test "comments and crawl delay do not become path rules" do
    rules =
      Robots.parse("""
      # comment
      User-agent: * # star
      Disallow: /secret # hidden
      Crawl-delay: 10
      """)

    refute Robots.allowed?(rules, "http://example.com/secret", "Crawler/1")
    assert Robots.allowed?(rules, "http://example.com/public", "Crawler/1")
  end

  test "nofollow and none apply from the page header and the matching meta name" do
    assert Robots.header_nofollow?([{"X-Robots-Tag", "nofollow"}], "Crawler/1")

    assert Robots.header_nofollow?(
             [{"x-robots-tag", "googlebot: nofollow, crawler: none"}],
             "Crawler/1"
           )

    refute Robots.header_nofollow?([{"x-robots-tag", "googlebot: nofollow"}], "Crawler/1")

    assert Robots.meta_nofollow?(~s|<meta name="robots" content="index, nofollow">|, "Crawler/1")
    assert Robots.meta_nofollow?(~s|<meta name="Crawler" content="none">|, "Crawler/1")
    refute Robots.meta_nofollow?(~s|<meta name="googlebot" content="nofollow">|, "Crawler/1")

    refute Robots.meta_nofollow?(
             ~s|<template><meta name="robots" content="nofollow"></template>|,
             "Crawler/1"
           )
  end
end
