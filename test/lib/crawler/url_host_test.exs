defmodule Crawler.URLHostTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker.Snapshot
  alias Crawler.URL
  alias Crawler.URL.Host

  test "the public host fold contract is shared by examples and URL normalization" do
    assert Host.fold("例。COM") == "xn--fsq.com"
    assert Host.fold("ＥＸＡＭＰＬＥ.com") == "example.com"
    assert Host.fold("e%78ample.com") == "example.com"
    assert Host.fold("0:0:0:0:0:0:0:1") == "::1"
  end

  test "maps Unicode separators, width, compatibility characters, and encoded hosts" do
    for {ascii, spellings} <- [
          {"xn--fsq.com", ["例.com", "例。com", "例．com", "例｡com", "%E4%BE%8B%EF%BC%8Ecom"]},
          {"foo.com", ["foo.com", "ｆoo.com", "ＦＯＯ．ＣＯＭ", "foo。com."]},
          {"example.com", ["example.com", "e%78ample.com", "%65xample%2ecom", "EXAMPLE.COM"]},
          {"viii.com", ["Ⅷ.com", "viii.com"]},
          {"xn--caf-dma.com", ["café.com", "cafe\u0301.com", "caf%C3%A9.com"]},
          {"xn--53h.example", ["☕.example", "xn--53h.example"]},
          {"xn--fa-hia.de", ["faß.de", "xn--fa-hia.de"]}
        ],
        host <- spellings do
      url = "http://#{host}/page"
      expected = "http://#{ascii}/page"

      assert URL.normalize(url) == expected
      assert URL.canonical(url) == expected
      assert URL.resolve(url, "http://base.com/") == {:ok, expected}
      assert URL.resolve("//#{host}/page", "http://base.com/") == {:ok, expected}
      assert Snapshot.path(url) == Snapshot.path(expected)
    end
  end

  test "keeps non-transitional Unicode domains and distinct IPv6 addresses separate" do
    for {left, right} <- [
          {"http://faß.de/page", "http://fass.de/page"},
          {"http://例.com/page", "http://例.net/page"},
          {"http://[fe80:1::1]/page", "http://[fe80::1]/page"},
          {"http://[::1]:81/page", "http://[::1]/page"}
        ] do
      refute URL.canonical(left) == URL.canonical(right)
      refute Snapshot.path(left) == Snapshot.path(right)
    end
  end

  test "rejects forbidden or invalid decoded domains" do
    for host <- [
          "exa%23mple.com",
          "exa%2fmple.com",
          "%00example.com",
          "ex%20ample.com",
          "ex%FFample.com",
          "ex%ZZample.com",
          "%EF%BF%BD.com",
          "a\u200Db.com"
        ] do
      assert URL.resolve("http://#{host}/page", "http://base.com/") == :skip
    end
  end

  test "preserves browser-permitted ASCII domains" do
    for host <- ["under_score.com", "-hyphen.com", "example.com..", "xn--8i7caa.com", "."] do
      assert URL.resolve("http://#{host}/page", "http://base.com/") ==
               {:ok, "http://#{host}/page"}
    end
  end
end
