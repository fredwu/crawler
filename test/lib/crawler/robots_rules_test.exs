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

  test "query rules use the real URL and a trailing dollar is its end" do
    rules =
      Robots.parse("""
      User-agent: *
      Disallow: /*.php$
      Disallow: /search?
      """)

    refute Robots.allowed?(rules, "http://example.com/file.php", "Crawler/1")
    assert Robots.allowed?(rules, "http://example.com/file.php?x=1", "Crawler/1")
    assert Robots.allowed?(rules, "http://example.com/search", "Crawler/1")
    refute Robots.allowed?(rules, "http://example.com/search?q=1", "Crawler/1")
    refute Robots.allowed?(rules, "http://example.com/search?", "Crawler/1")
  end

  test "a query wildcard blocks URLs with a question mark" do
    rules = Robots.parse("User-agent: *\nDisallow: /*?\n")

    assert Robots.allowed?(rules, "http://example.com/docs", "Crawler/1")
    refute Robots.allowed?(rules, "http://example.com/docs?x=1", "Crawler/1")
    assert Robots.allowed?(rules, "http://example.com/file.php", "Crawler/1")
    refute Robots.allowed?(rules, "http://example.com/file.php?x=1", "Crawler/1")
  end

  test "an end anchor allows the same path when a query is present" do
    rules = Robots.parse("User-agent: *\nDisallow: /*.php$\n")

    refute Robots.allowed?(rules, "http://example.com/file.php", "Crawler/1")
    assert Robots.allowed?(rules, "http://example.com/file.php?x=1", "Crawler/1")
    assert Robots.allowed?(rules, "http://example.com/file.phpx", "Crawler/1")
  end

  test "encoded and plain spellings are the same robots path" do
    rules =
      Robots.parse("""
      User-agent: *
      Disallow: /foo/%62%61%7A
      Disallow: /bar/%E3%83%84
      Disallow: /a%2Fb
      Disallow: /star/%2A
      Disallow: /price/%24
      """)

    refute Robots.allowed?(rules, "http://example.com/foo/baz", "Crawler/1")
    refute Robots.allowed?(rules, "http://example.com/foo/%62%61%7A", "Crawler/1")
    refute Robots.allowed?(rules, "http://example.com/bar/ツ", "Crawler/1")
    refute Robots.allowed?(rules, "http://example.com/bar/%E3%83%84", "Crawler/1")
    refute Robots.allowed?(rules, "http://example.com/a%2Fb", "Crawler/1")
    refute Robots.allowed?(rules, "http://example.com/a%2fb", "Crawler/1")
    assert Robots.allowed?(rules, "http://example.com/a/b", "Crawler/1")
    refute Robots.allowed?(rules, "http://example.com/star/*", "Crawler/1")
    refute Robots.allowed?(rules, "http://example.com/star/%2A", "Crawler/1")
    assert Robots.allowed?(rules, "http://example.com/star/other", "Crawler/1")
    refute Robots.allowed?(rules, "http://example.com/star/%2a", "Crawler/1")
    refute Robots.allowed?(rules, "http://example.com/price/$", "Crawler/1")
    refute Robots.allowed?(rules, "http://example.com/price/%24", "Crawler/1")
    assert Robots.allowed?(rules, "http://example.com/price/%2524", "Crawler/1")
    assert Robots.allowed?(rules, "http://example.com/price/end", "Crawler/1")

    encoded_dollar = Robots.parse("User-agent: *\nDisallow: /price/%2524\n")
    refute Robots.allowed?(encoded_dollar, "http://example.com/price/%2524", "Crawler/1")
    assert Robots.allowed?(encoded_dollar, "http://example.com/price/%24", "Crawler/1")
    assert Robots.allowed?(encoded_dollar, "http://example.com/price/$", "Crawler/1")
  end

  test "equivalent spellings tie and Allow wins" do
    rules =
      Robots.parse("""
      User-agent: *
      Disallow: /foo/%62%61%7A
      Allow: /foo/baz
      """)

    assert Robots.allowed?(rules, "http://example.com/foo/baz", "Crawler/1")
  end

  test "the longest named product selects the group" do
    rules =
      Robots.parse("""
      User-agent: *
      Disallow: /

      User-agent: Crawler/1.2
      Disallow: /hidden

      User-agent: CrawlerBot
      Disallow: /bot

      User-agent: Crawler-News
      Disallow: /news
      """)

    assert Robots.allowed?(rules, "http://example.com/docs", "Crawler/1.5.0")
    refute Robots.allowed?(rules, "http://example.com/hidden", "Crawler/1.5.0")
    assert Robots.allowed?(rules, "http://example.com/bot", "Crawler/1.5.0")

    assert Robots.allowed?(
             rules,
             "http://example.com/docs",
             "Mozilla/5.0 (compatible; CrawlerBot/1.0)"
           )

    refute Robots.allowed?(
             rules,
             "http://example.com/bot",
             "Mozilla/5.0 (compatible; CrawlerBot/1.0)"
           )

    assert Robots.allowed?(
             rules,
             "http://example.com/hidden",
             "Mozilla/5.0 (compatible; CrawlerBot/1.0)"
           )

    refute Robots.allowed?(rules, "http://example.com/news", "Crawler-News/1.0")
    assert Robots.allowed?(rules, "http://example.com/hidden", "Crawler-News/1.0")

    refute Robots.allowed?(
             rules,
             "http://example.com/bot",
             "Mozilla/5.0 (compatible; Crawler/1.0; CrawlerBot/2.0)"
           )

    assert Robots.allowed?(
             rules,
             "http://example.com/hidden",
             "Mozilla/5.0 (compatible; Crawler/1.0; CrawlerBot/2.0)"
           )
  end

  test "a Crawler star rule is the Crawler group and a later token still matches" do
    rules =
      Robots.parse("""
      User-agent: *
      Disallow: /

      User-agent: Mozilla
      Disallow: /

      User-agent: Crawler*
      Disallow: /hidden
      """)

    assert Robots.allowed?(
             rules,
             "http://example.com/docs",
             "Mozilla/5.0 (compatible; Crawler/1.0)"
           )

    refute Robots.allowed?(
             rules,
             "http://example.com/hidden",
             "Mozilla/5.0 (compatible; Crawler/1.0)"
           )

    assert Robots.allowed?(rules, "http://example.com/docs", "Crawler/1.5.0")
  end

  test "a version number is not a product group" do
    rules =
      Robots.parse("""
      User-agent: *
      Disallow: /secret

      User-agent: 5
      Disallow: /

      User-agent: Crawler2
      Disallow: /two
      """)

    assert Robots.allowed?(rules, "http://example.com/docs", "Crawler/1.5.0")
    refute Robots.allowed?(rules, "http://example.com/secret", "Crawler/1.5.0")
    assert Robots.allowed?(rules, "http://example.com/two", "Crawler/1.0")
    refute Robots.allowed?(rules, "http://example.com/two", "Crawler2/1.0")
    assert Robots.allowed?(rules, "http://example.com/secret", "Crawler2/1.0")
  end

  test "a leading byte-order mark keeps the first group" do
    rules = Robots.parse(<<0xEF, 0xBB, 0xBF>> <> "User-agent: *\nDisallow: /secret\n")

    refute Robots.allowed?(rules, "http://example.com/secret", "Crawler/1")
    assert Robots.allowed?(rules, "http://example.com/docs", "Crawler/1")
  end

  test "a sitemap line stays in the group and is kept" do
    rules =
      Robots.parse("""
      Sitemap: https://cdn.example/sitemap.xml

      User-agent: *
      Disallow: /secret
      Sitemap: https://cdn.example/more.xml
      Allow: /secret/ok

      User-agent: Crawler
      Disallow: /hidden
      """)

    refute Robots.allowed?(rules, "http://example.com/secret", "Other/1")
    assert Robots.allowed?(rules, "http://example.com/secret/ok", "Other/1")
    refute Robots.allowed?(rules, "http://example.com/hidden", "Crawler/1")
    assert Robots.allowed?(rules, "http://example.com/secret", "Crawler/1")

    assert rules.sitemaps == [
             "https://cdn.example/sitemap.xml",
             "https://cdn.example/more.xml"
           ]
  end

  test "nofollow matches a product token that is not first" do
    ua = "Mozilla/5.0 (compatible; Crawler/1.0)"

    assert Robots.header_nofollow?([{"x-robots-tag", "crawler: nofollow"}], ua)
    refute Robots.header_nofollow?([{"x-robots-tag", "googlebot: nofollow"}], ua)
    assert Robots.meta_nofollow?(~s|<meta name="crawler" content="nofollow">|, ua)
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
