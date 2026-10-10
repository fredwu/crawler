defmodule Crawler.CookiesTest do
  use ExUnit.Case, async: true

  alias Crawler.Cookies

  test "host-only cookies follow the request path and stay on that host" do
    jar =
      Cookies.store([], "http://example.com/page", [
        "session=abc; Path=/",
        "admin=1; Path=/admin"
      ])

    assert pairs(Cookies.header(jar, "http://example.com/page")) == %{"session" => "abc"}

    assert pairs(Cookies.header(jar, "http://example.com/admin/users")) == %{
             "session" => "abc",
             "admin" => "1"
           }

    assert Cookies.header(jar, "http://www.example.com/page") == nil
    assert Cookies.header(jar, "http://other.test/page") == nil
  end

  test "a missing path uses the request directory" do
    jar = Cookies.store([], "http://example.com/foo/bar", ["id=1"])

    assert Cookies.header(jar, "http://example.com/foo") == "id=1"
    assert Cookies.header(jar, "http://example.com/foo/other") == "id=1"
    assert Cookies.header(jar, "http://example.com/foobar") == nil
    assert Cookies.header(jar, "http://example.com/") == nil
  end

  test "a domain cookie is stored only when it covers the response host" do
    jar = Cookies.store([], "http://example.com/a", ["id=1; Domain=example.com"])

    assert Cookies.header(jar, "http://www.example.com/a") == "id=1"
    assert Cookies.header(jar, "http://example.com/a") == "id=1"
    assert Cookies.header(jar, "http://notexample.com/a") == nil

    assert Cookies.store([], "http://example.com/a", ["id=1; Domain=evil.com"]) == []
    assert Cookies.store([], "http://127.0.0.1/a", ["id=1; Domain=127.0.0.1"]) == []

    assert Cookies.header(Cookies.store([], "http://127.0.0.1/a", ["id=1"]), "http://127.0.0.1/b") ==
             "id=1"
  end

  test "secure cookies stay on https and expiry removes a cookie" do
    secure = Cookies.store([], "https://example.com/a", ["id=1; Secure; HttpOnly"])
    assert Cookies.header(secure, "https://example.com/b") == "id=1"
    assert Cookies.header(secure, "http://example.com/b") == nil

    expired =
      Cookies.store([], "http://example.com/a", ["id=1; Expires=Tue, 01 Jan 1980 00:00:00 GMT"])

    assert expired == []

    kept =
      Cookies.store([], "http://example.com/a", [
        "id=1; Max-Age=60; Expires=Tue, 01 Jan 1980 00:00:00 GMT"
      ])

    assert Cookies.header(kept, "http://example.com/b") == "id=1"

    deleted = Cookies.store(kept, "http://example.com/a", ["id=1; Max-Age=0"])
    assert Cookies.header(deleted, "http://example.com/b") == nil

    invalid_age =
      Cookies.store([], "http://example.com/a", [
        "id=1; Max-Age=nope; Expires=Tue, 01 Jan 1980 00:00:00 GMT"
      ])

    assert invalid_age == []

    invalid_date = Cookies.store([], "http://example.com/a", ["id=1; Expires=not-a-date"])
    assert Cookies.header(invalid_date, "http://example.com/b") == "id=1"
  end

  test "a dashed expires date deletes a cookie and max-age is checked again later" do
    dashed =
      Cookies.store([], "http://example.com/a", ["id=1; Expires=Thu, 01-Jan-1970 00:00:01 GMT"])

    assert dashed == []

    rfc850 =
      Cookies.store([], "http://example.com/a", [
        "id=1; Expires=Thursday, 01-Jan-1970 00:00:01 GMT"
      ])

    assert rfc850 == []

    future =
      Cookies.store([], "http://example.com/a", ["id=1; Expires=Thu, 01-Jan-2099 00:00:00 GMT"])

    assert Cookies.header(future, "http://example.com/b") == "id=1"

    url = "http://example.com/a"

    jar =
      Cookies.store([], url, [
        "id=1; Max-Age=1; Expires=Thu, 01-Jan-2099 00:00:00 GMT; Path=/"
      ])

    assert [%{expires_at: deadline}] = jar

    if DateTime.compare(deadline, DateTime.utc_now()) == :gt do
      assert Cookies.header(jar, url) == "id=1"
    end

    wait_until_expired(jar)
    assert Cookies.header(jar, url) == nil
  end

  test "a public suffix cannot be a cookie domain" do
    assert Cookies.store([], "http://a.com/a", ["stolen=1; Domain=com"]) == []
    assert Cookies.store([], "http://shop.example.co.uk/a", ["id=1; Domain=co.uk"]) == []
    assert Cookies.store([], "http://a.com.au/a", ["id=1; Domain=com.au"]) == []
    assert Cookies.store([], "http://a.github.io/a", ["id=1; Domain=github.io"]) == []

    assert Cookies.store([], "http://bucket.s3.amazonaws.com/a", [
             "id=1; Domain=s3.amazonaws.com"
           ]) == []

    assert Cookies.store([], "http://www.ck/a", ["id=1; Domain=ck"]) == []
    assert Cookies.store([], "http://www.foo.ck/a", ["id=1; Domain=foo.ck"]) == []

    shared = Cookies.store([], "http://www.example.com/a", ["id=1; Domain=example.com"])
    assert Cookies.header(shared, "http://shop.example.com/a") == "id=1"
    assert Cookies.header(shared, "http://example.org/a") == nil

    uk = Cookies.store([], "http://www.example.co.uk/a", ["id=1; Domain=example.co.uk"])
    assert Cookies.header(uk, "http://shop.example.co.uk/a") == "id=1"
    assert Cookies.header(uk, "http://other.co.uk/a") == nil

    pages = Cookies.store([], "http://foo.a.github.io/a", ["id=1; Domain=a.github.io"])
    assert Cookies.header(pages, "http://bar.a.github.io/a") == "id=1"
    assert Cookies.header(pages, "http://b.github.io/a") == nil

    host_only = Cookies.store([], "http://a.github.io/a", ["id=1"])
    assert Cookies.header(host_only, "http://a.github.io/b") == "id=1"
    assert Cookies.header(host_only, "http://b.github.io/b") == nil

    exception = Cookies.store([], "http://www.ck/a", ["id=1; Domain=www.ck"])
    assert Cookies.header(exception, "http://www.ck/b") == "id=1"
    assert Cookies.header(exception, "http://other.ck/b") == nil

    bucket =
      Cookies.store([], "http://x.bucket.s3.amazonaws.com/a", [
        "id=1; Domain=bucket.s3.amazonaws.com"
      ])

    assert Cookies.header(bucket, "http://y.bucket.s3.amazonaws.com/a") == "id=1"

    nested =
      Cookies.store([], "http://bar.foo.ck/a", ["id=1; Domain=bar.foo.ck"])

    assert Cookies.header(nested, "http://shop.bar.foo.ck/a") == "id=1"
    assert Cookies.header(nested, "http://other.foo.ck/a") == nil
  end

  test "a trailing dot and a unicode domain match in ascii form" do
    dotted = Cookies.store([], "http://www.example.com/a", ["id=1; Domain=example.com."])

    assert [%{domain: "example.com", host_only?: false}] = dotted
    assert Cookies.header(dotted, "http://shop.example.com/a") == "id=1"

    unicode =
      Cookies.store([], "http://www.xn--exmple-cua.com/a", ["id=1; Domain=EXÄMPLE.COM."])

    assert [%{domain: "exämple.com", host_only?: false}] = unicode
    assert Cookies.header(unicode, "http://shop.xn--exmple-cua.com/a") == "id=1"
    assert Cookies.header(unicode, "http://example.org/a") == nil
  end

  test "a year below 1601 makes the expires date invalid" do
    early =
      Cookies.store([], "http://example.com/a", ["id=1; Expires=01 Jan 1500 00:00:00 GMT 2099"])

    assert [%{expires_at: nil}] = early
    assert Cookies.header(early, "http://example.com/b") == "id=1"

    sixteen =
      Cookies.store([], "http://example.com/a", ["id=1; Expires=01 Jan 1600 00:00:00 GMT"])

    assert [%{expires_at: nil}] = sixteen
    assert Cookies.header(sixteen, "http://example.com/b") == "id=1"

    assert Cookies.store([], "http://example.com/a", ["id=1; Expires=01 Jan 1601 00:00:00 GMT"]) ==
             []
  end

  test "a huge max-age is capped instead of walking the calendar" do
    started = System.monotonic_time(:millisecond)

    jar =
      Cookies.store([], "http://example.com/a", ["id=1; Max-Age=100000000000000000000"])

    assert System.monotonic_time(:millisecond) - started < 1_000
    assert [%{expires_at: %DateTime{year: 9999}}] = jar
    assert Cookies.header(jar, "http://example.com/b") == "id=1"
  end

  test "a domain attribute on an address is rejected after trailing dots are removed" do
    assert Cookies.store([], "http://127.0.0.1../a", ["id=1; Domain=127.0.0.1"]) == []
    assert Cookies.store([], "http://127.0.0.1../a", ["id=1; Domain=127.0.0.1."]) == []
    assert Cookies.store([], "http://evil.127.0.0.1/a", ["id=1; Domain=127.0.0.1"]) == []

    host_only = Cookies.store([], "http://127.0.0.1../a", ["id=1"])
    assert [%{domain: "127.0.0.1", host_only?: true}] = host_only
    assert Cookies.header(host_only, "http://127.0.0.1../b") == "id=1"
    assert Cookies.header(host_only, "http://evil.127.0.0.1/a") == nil
  end

  test "a trailing-dot host-only cookie is replaced on the bare host" do
    jar = Cookies.store([], "http://example.com../a", ["id=1"])

    assert [%{domain: "example.com", host_only?: true}] = jar
    assert Cookies.header(jar, "http://example.com/b") == "id=1"
    assert Cookies.header(jar, "http://www.example.com/b") == nil

    replaced = Cookies.store(jar, "http://example.com./a", ["id=2"])
    assert [%{domain: "example.com", value: "2"}] = replaced
    assert Cookies.header(replaced, "http://example.com../b") == "id=2"

    assert Cookies.store(jar, "http://example.com/a", ["id=1; Max-Age=0"]) == []
  end

  test "a domain attribute that is not utf-8 is ignored" do
    header = "id=1; Domain=ex" <> <<255>> <> "ample.com"

    assert [%{name: "ok", value: "1", host_only?: true}] =
             Cookies.store([], "http://example.com/a", [header, "ok=1"])
  end

  test "another idna spelling of the same domain replaces the cookie" do
    planted = Cookies.store([], "http://www.example.com/a", ["id=1; Domain=example。com"])
    assert [%{domain: "example。com", host_only?: false}] = planted
    assert Cookies.header(planted, "http://shop.example.com/a") == "id=1"

    assert Cookies.store(planted, "http://www.example.com/a", [
             "id=1; Domain=example.com; Max-Age=0"
           ]) ==
             []

    unicode =
      Cookies.store([], "http://www.xn--exmple-cua.com/a", ["id=1; Domain=exämple.com"])

    assert [%{domain: "exämple.com"}] = unicode

    assert Cookies.store(unicode, "http://www.xn--exmple-cua.com/a", [
             "id=1; Domain=xn--exmple-cua.com; Max-Age=0"
           ]) == []
  end

  test "a domain attribute that is an address only after idna is rejected" do
    assert Cookies.store([], "http://evil.127.0.0.1/a", ["id=1; Domain=１２７.０.０.１"]) == []
    assert Cookies.store([], "http://evil.127.0.0.1/a", ["id=1; Domain=127.0.0.1。"]) == []
  end

  test "a trailing unicode full stop is removed after idna" do
    jar = Cookies.store([], "http://www.example.com/a", ["id=1; Domain=example.com。"])

    assert [%{domain: "example.com。", host_only?: false}] = jar
    assert Cookies.header(jar, "http://shop.example.com/a") == "id=1"
    assert Cookies.header(jar, "http://example.org/a") == nil

    assert Cookies.store(jar, "http://www.example.com/a", ["id=1; Domain=example.com; Max-Age=0"]) ==
             []

    assert Cookies.store([], "http://a.com/a", ["id=1; Domain=com．"]) == []
  end

  test "an empty label cannot hide a public suffix" do
    assert Cookies.store([], "http://shop.brand.co..uk/a", ["id=1; Domain=co..uk"]) == []
    assert Cookies.store([], "http://a..com/a", ["id=1; Domain=。com"]) == []

    jar = Cookies.store([], "http://www.example.com/a", ["id=1; Domain=。example.com"])
    assert [%{domain: "。example.com", host_only?: false}] = jar
    assert Cookies.header(jar, "http://shop.example.com/a") == "id=1"
    assert Cookies.header(jar, "http://example.org/a") == nil

    host_only = Cookies.store([], "http://example..com/a", ["id=1"])
    assert Cookies.header(host_only, "http://example..com/b") == "id=1"
    assert Cookies.header(host_only, "http://example.com/b") == nil
  end

  test "the jar value replaces the same cookie name from the user header" do
    assert pairs(Cookies.merge_header("session=old; extra=1", "session=new")) == %{
             "session" => "new",
             "extra" => "1"
           }

    assert Cookies.merge_header("session=old", nil) == "session=old"
    assert Cookies.merge_header(nil, nil) == nil
  end

  defp wait_until_expired([%{expires_at: %DateTime{} = deadline} | _]) do
    delay = DateTime.diff(deadline, DateTime.utc_now(), :millisecond) + 50
    if delay > 0, do: Process.sleep(delay)
  end

  defp pairs(nil), do: %{}

  defp pairs(header) do
    Map.new(String.split(header, ";"), fn piece ->
      [name, value] = piece |> String.trim() |> String.split("=", parts: 2)
      {name, value}
    end)
  end
end
