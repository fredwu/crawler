defmodule Crawler.URLIPv4Test do
  use ExUnit.Case, async: true

  alias Crawler.Linker.Snapshot
  alias Crawler.URL
  alias Crawler.URL.Host

  test "normalizes browser IPv4 spellings to one address and saved path" do
    for {address, spellings} <- [
          {"127.0.0.1",
           [
             "127.0.0.1",
             "127.1",
             "127.0.1",
             "2130706433",
             "0x7f000001",
             "0X7F.0.0.1",
             "0177.0.0.1",
             "017700000001",
             "127.0.0.1.",
             "１２７。０．０｡１",
             "%31%32%37.1"
           ]},
          {"0.0.0.0", ["0", "00", "0x", "0X.0.0.0"]},
          {"255.255.255.255", ["4294967295", "0xffffffff", "037777777777"]},
          {"1.255.255.255", ["1.16777215"]},
          {"1.2.255.255", ["1.2.65535"]},
          {"1.2.3.255", ["1.2.3.255"]}
        ],
        spelling <- spellings do
      url = "http://#{spelling}/page"
      expected = "http://#{address}/page"

      assert Host.domain(spelling) == {:ok, address}
      assert Host.fold(spelling) == address
      assert URL.normalize(url) == expected
      assert URL.canonical(url) == expected
      assert URL.resolve(url, "http://base.com/") == {:ok, expected}
      assert URL.resolve("//#{spelling}/page", "http://base.com/") == {:ok, expected}
      assert Snapshot.path(url) == Snapshot.path(expected)
    end
  end

  test "rejects numeric hosts with invalid parts or ranges" do
    for host <- [
          "09",
          "08.0.0.1",
          "0xg.0.0.1",
          "+1.0.0.1",
          "-1.0.0.1",
          "1e2.0.0.1",
          "1..1",
          ".1",
          "1.2.3.4.5",
          "256.0.0.1",
          "1.256.0.1",
          "1.2.256.1",
          "1.2.3.256",
          "1.2.65536",
          "1.16777216",
          "4294967296",
          "0x100000000",
          "040000000000",
          "999999999999999999999999999999999999999999",
          "example.42",
          "example.0x",
          "example.0xff.",
          "example.09",
          "１２７。０。０。２５６"
        ] do
      assert Host.domain(host) == :error
      assert URL.resolve("http://#{host}/page", "http://base.com/") == :skip
      assert URL.resolve("//#{host}/page", "http://base.com/") == :skip
    end
  end

  test "preserves domains without a numeric ending and repeated trailing dots" do
    for host <- ["123.example", "example.0xg", "example.1e2", "127.0.0.1..", ".", ".."] do
      assert Host.domain(host) == {:ok, host}

      assert URL.resolve("http://#{host}/page", "http://base.com/") ==
               {:ok, "http://#{host}/page"}
    end

    assert Host.domain("example.com.") == {:ok, "example.com"}
    assert Host.domain("example.com..") == {:ok, "example.com.."}
    assert Host.ipv6("::ffff:127.0.0.1") == {:ok, "::ffff:7f00:1"}
    assert URL.normalize("http://[::1]/page") == "http://[::1]/page"
    refute Snapshot.path("http://127.0.0.1/page") == Snapshot.path("http://127.0.0.1../page")
  end
end
