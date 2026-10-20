defmodule Crawler.CookiesTest do
  use ExUnit.Case, async: true

  alias Crawler.Cookies
  alias Crawler.Cookies.PublicSuffix

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

  test "a host-prefix cookie stays on the exact host that set it" do
    nested = "https://www.example.com/account/x"

    assert Cookies.store([], nested, ["__Host-session=1; Domain=example.com; Path=/; Secure"]) ==
             []

    assert Cookies.store([], nested, ["__Host-session=1; Path=/admin; Secure"]) == []
    assert Cookies.store([], nested, ["__Host-session=1; Secure"]) == []

    assert Cookies.store([], "http://www.example.com/", ["__Host-session=1; Path=/; Secure"]) ==
             []

    explicit =
      Cookies.store([], nested, ["__Host-session=1; Path=/; Secure"])

    assert [%{host_only?: true, secure?: true, path: "/", domain: "www.example.com"}] = explicit
    assert Cookies.header(explicit, "https://www.example.com/admin/y") == "__Host-session=1"
    assert Cookies.header(explicit, "https://example.com/") == nil
    assert Cookies.header(explicit, "https://shop.example.com/") == nil
    assert Cookies.header(explicit, "http://www.example.com/") == nil

    rooted = Cookies.store([], "https://example.com/", ["__Host-id=1; Secure"])
    assert [%{host_only?: true, path: "/", domain: "example.com"}] = rooted
    assert Cookies.header(rooted, "https://example.com/account") == "__Host-id=1"
    assert Cookies.header(rooted, "https://www.example.com/") == nil
  end

  test "a secure-prefix cookie is stored only with the secure flag and sent only over https" do
    assert Cookies.store([], "https://example.com/", ["__Secure-id=1"]) == []
    assert Cookies.store([], "http://example.com/", ["__Secure-ok=1; Secure"]) == []

    jar =
      Cookies.store([], "https://www.example.com/account", [
        "__Secure-ok=1; Domain=example.com; Path=/; Secure"
      ])

    assert [%{name: "__Secure-ok", secure?: true, host_only?: false}] = jar
    assert Cookies.header(jar, "https://shop.example.com/account") == "__Secure-ok=1"
    assert Cookies.header(jar, "http://shop.example.com/account") == nil
    assert Cookies.header(jar, "http://www.example.com/") == nil
  end

  test "an http response cannot plant or replace a secure cookie" do
    jar = Cookies.store([], "https://example.com/", ["id=good; Secure; Path=/"])
    assert Cookies.header(jar, "https://example.com/account") == "id=good"
    assert Cookies.header(jar, "http://example.com/account") == nil

    assert Cookies.store([], "http://example.com/", ["id=planted; Secure; Path=/"]) == []

    replaced = Cookies.store(jar, "http://example.com/", ["id=evil; Path=/"])
    assert [%{name: "id", value: "good", secure?: true}] = replaced

    domain_shaped =
      Cookies.store(replaced, "http://example.com/", ["id=evil; Domain=example.com; Path=/"])

    assert [%{name: "id", value: "good", host_only?: true}] = domain_shaped

    deleted = Cookies.store(domain_shaped, "http://example.com/", ["id=good; Max-Age=0; Path=/"])
    assert Cookies.header(deleted, "https://example.com/") == "id=good"

    kept =
      Cookies.store(deleted, "http://example.com/admin", ["side=1; Path=/admin"])

    assert pairs(Cookies.header(kept, "http://example.com/admin")) == %{"side" => "1"}
    assert Cookies.header(kept, "https://example.com/") == "id=good"

    updated = Cookies.store(kept, "https://example.com/", ["id=better; Secure; Path=/"])
    assert Cookies.header(updated, "https://example.com/") == "id=better"
    assert pairs(Cookies.header(updated, "http://example.com/admin")) == %{"side" => "1"}
  end

  test "a lowercase host or secure prefix is an ordinary cookie" do
    jar =
      Cookies.store([], "https://www.example.com/", [
        "__host-id=1; Domain=example.com; Path=/; Secure"
      ])

    assert [%{name: "__host-id", host_only?: false, secure?: true}] = jar
    assert Cookies.header(jar, "https://shop.example.com/") == "__host-id=1"
    assert Cookies.header(jar, "http://shop.example.com/") == nil

    plain = Cookies.store([], "https://example.com/", ["__secure-id=1; Path=/"])
    assert [%{name: "__secure-id", secure?: false, host_only?: true}] = plain
    assert Cookies.header(plain, "http://example.com/account") == "__secure-id=1"
    assert Cookies.header(plain, "http://www.example.com/") == nil
  end

  test "the registrable domain is the public suffix plus one label" do
    assert PublicSuffix.registrable_domain("example.com") == "example.com"
    assert PublicSuffix.registrable_domain("www.example.com") == "example.com"
    assert PublicSuffix.registrable_domain("WWW.Example.CO.UK.") == "example.co.uk"
    assert PublicSuffix.registrable_domain("foo.a.github.io") == "a.github.io"
    assert PublicSuffix.registrable_domain("b.github.io") == "b.github.io"
    assert PublicSuffix.registrable_domain("github.io") == "github.io"
    assert PublicSuffix.registrable_domain("www.ck") == "www.ck"
    assert PublicSuffix.registrable_domain("other.ck") == "other.ck"
    assert PublicSuffix.registrable_domain("shop.bar.foo.ck") == "bar.foo.ck"
    assert PublicSuffix.registrable_domain("127.0.0.1") == "127.0.0.1"
    assert PublicSuffix.registrable_domain("2001:db8::1") == "2001:db8::1"
    assert PublicSuffix.registrable_domain("") == ""
    assert PublicSuffix.registrable_domain(nil) == ""
    assert PublicSuffix.registrable_domain("foo..com") == ""
  end

  test "no samesite or an unknown samesite is lax and is withheld from a cross-site subresource" do
    jar =
      Cookies.store([], "https://cdn.test/app.js", [
        "plain=1; Path=/",
        "odd=1; Path=/; SameSite=Invalid"
      ])

    cross = %{site: "http://example.com/start", navigation: false}
    assert Cookies.header(jar, "https://cdn.test/next.js", cross) == nil

    same = %{site: "https://www.cdn.test/page", navigation: false}
    assert Cookies.header(jar, "https://cdn.test/next.js", same) == "plain=1; odd=1"

    opened = %{site: "http://example.com/start", navigation: true}
    assert Cookies.header(jar, "https://cdn.test/next.js", opened) == "plain=1; odd=1"
  end

  test "samesite none is stored only with secure on https and is sent across sites" do
    jar =
      Cookies.store([], "https://cdn.test/app.js", ["cdn=1; Path=/; Secure; SameSite=NONE"])

    cross = %{site: "http://example.com/start", navigation: false}
    assert Cookies.header(jar, "https://cdn.test/next.js", cross) == "cdn=1"
    assert Cookies.header(jar, "http://cdn.test/next.js", cross) == nil

    assert Cookies.store([], "https://cdn.test/app.js", ["cdn=1; Path=/; SameSite=None"]) == []

    assert Cookies.store([], "http://cdn.test/app.js", ["cdn=1; Path=/; Secure; SameSite=None"]) ==
             []
  end

  test "strict stays on the same site and lax can cross on a document navigation" do
    jar =
      Cookies.store([], "https://other.test/", [
        "strict=1; SameSite=Strict; Path=/",
        "lax=1; Path=/"
      ])

    navigation = %{site: "https://example.com/start", navigation: true}
    assert Cookies.header(jar, "https://other.test/land", navigation) == "lax=1"

    script = %{site: "https://example.com/start", navigation: false}
    assert Cookies.header(jar, "https://other.test/app.js", script) == nil

    same = %{site: "https://www.other.test/page", navigation: false}
    assert Cookies.header(jar, "https://other.test/app.js", same) == "strict=1; lax=1"
  end

  test "a partitioned cookie belongs to the page site and does not replace an unpartitioned cookie" do
    page = %{site: "https://example.com/start", navigation: false}
    other = %{site: "https://other.test/page", navigation: false}
    url = "https://cdn.test/app.js"

    jar =
      Cookies.store(nil, url, ["part=1; Path=/; Secure; SameSite=None; Partitioned"], page)

    jar = Cookies.store(jar, url, ["part=2; Path=/; Secure; SameSite=None"], page)

    jar =
      Cookies.store(jar, url, ["part=3; Path=/; Secure; SameSite=None; Partitioned"], page)

    assert Cookies.header(jar, "https://cdn.test/next.js", page) == "part=3; part=2"

    assert Cookies.header(jar, "https://cdn.test/next.js", %{
             site: "http://www.example.com:8443/side",
             navigation: false
           }) == "part=3; part=2"

    assert Cookies.header(jar, "https://cdn.test/next.js", other) == "part=2"
    assert Cookies.header(jar, "https://www.example.com/next.js", page) == nil

    plain = Cookies.store([], url, ["cdn=1; Path=/; Secure; SameSite=None"], page)
    assert Cookies.header(plain, "https://cdn.test/next.js", other) == "cdn=1"
  end

  test "matching cookies are sent longest path first and an update keeps its place" do
    url = "https://example.com/account/x"

    jar =
      Cookies.store([], url, [
        "id=1; Path=/",
        "id=2; Path=/account",
        "session=old; Path=/",
        "theme=1; Path=/"
      ])

    assert Cookies.header(jar, url) == "id=2; id=1; session=old; theme=1"

    updated = Cookies.store(jar, url, ["session=new; Path=/"])
    assert Cookies.header(updated, url) == "id=2; id=1; session=new; theme=1"
  end

  test "lax cookies use the registrable domain and ignore scheme and port" do
    jar =
      Cookies.store([], "http://example.com/start", [
        "shared=1; Domain=example.com; Path=/",
        "local=1; Path=/"
      ])

    page = %{site: "http://example.com/start", navigation: false}
    assert Cookies.header(jar, "https://cdn.example.com/app.js", page) == "shared=1"
    assert Cookies.header(jar, "https://cdn.test/app.js", page) == nil
    assert Cookies.header(jar, "https://example.com/secure.js", page) == "shared=1; local=1"
    assert Cookies.header(jar, "http://example.com:8443/port.js", page) == "shared=1; local=1"

    linked = %{site: "http://example.com/start", navigation: true}
    assert Cookies.header(jar, "https://www.example.com/page", linked) == "shared=1"

    pages = Cookies.store([], "https://a.github.io/", ["id=1; Domain=a.github.io; Path=/"])

    assert Cookies.header(pages, "https://a.github.io/next.js", %{
             site: "https://b.github.io/home",
             navigation: false
           }) == nil

    assert Cookies.header(pages, "https://foo.a.github.io/next.js", %{
             site: "https://a.github.io/home",
             navigation: false
           }) == "id=1"

    assert Cookies.header(pages, "https://b.github.io/", %{
             site: "https://a.github.io/",
             navigation: true
           }) == nil

    suffix = Cookies.store([], "https://other.ck/", ["id=1; Path=/"])

    assert Cookies.header(suffix, "https://other.ck/a", %{
             site: "https://www.ck/",
             navigation: false
           }) == nil

    assert Cookies.header(suffix, "https://other.ck/a", %{
             site: "https://other.ck:8443/",
             navigation: false
           }) == "id=1"

    nested =
      Cookies.store([], "https://bar.foo.ck/", ["id=1; Domain=bar.foo.ck; Path=/"])

    assert Cookies.header(nested, "https://shop.bar.foo.ck/a", %{
             site: "https://bar.foo.ck/",
             navigation: false
           }) == "id=1"

    assert Cookies.header(nested, "https://shop.bar.foo.ck/a", %{
             site: "https://other.foo.ck/",
             navigation: false
           }) == nil
  end

  test "request credentials narrow cookies to the document origin or site" do
    jar =
      Cookies.store([], "https://www.example.com/start", [
        "session=1; Domain=example.com; Path=/; SameSite=Lax",
        "open=1; Domain=example.com; Path=/; Secure; SameSite=None"
      ])

    page = "https://www.example.com/start"
    origin = %{site: page, navigation: false, credentials: :same_origin}

    assert Cookies.header(jar, "https://www.example.com/app.js", origin) == "session=1; open=1"

    assert Cookies.header(jar, "https://www.example.com:443/app.js", origin) ==
             "session=1; open=1"

    assert Cookies.header(jar, "https://WWW.example.com/app.js", origin) == "session=1; open=1"
    assert Cookies.header(jar, "https://cdn.example.com/app.js", origin) == nil
    assert Cookies.header(jar, "https://www.example.com:8443/app.js", origin) == nil
    assert Cookies.header(jar, "http://www.example.com/app.js", origin) == nil
    assert Cookies.header(jar, "https://other.test/app.js", origin) == nil

    site = %{site: page, navigation: false, credentials: :same_site}
    assert Cookies.header(jar, "https://cdn.example.com/app.js", site) == "session=1; open=1"
    assert Cookies.header(jar, "https://other.test/app.js", site) == nil
    assert Cookies.header(jar, "http://cdn.example.com/app.js", site) == "session=1"

    assert Cookies.header(jar, "https://other.test/app.js", %{site: page, navigation: true}) ==
             nil

    assert Cookies.header(jar, "https://other.test/app.js", %{site: page, navigation: false}) ==
             nil

    forced = %{site: page, navigation: true, credentials: :same_site}
    assert Cookies.header(jar, "https://other.test/app.js", forced) == nil
    assert Cookies.header(jar, "https://cdn.example.com/app.js", forced) == "session=1; open=1"

    foreign =
      Cookies.store([], "https://other.test/", [
        "session=1; Path=/; SameSite=Lax",
        "open=1; Path=/; Secure; SameSite=None"
      ])

    opened = %{site: page, navigation: true}
    assert Cookies.header(foreign, "https://other.test/app.js", opened) == "session=1; open=1"
    closed = %{site: page, navigation: false}
    assert Cookies.header(foreign, "https://other.test/app.js", closed) == "open=1"
    assert Cookies.header(foreign, "https://other.test/app.js", origin) == nil
    assert Cookies.header(foreign, "https://other.test/app.js", site) == nil
    assert Cookies.header(foreign, "https://other.test/app.js", forced) == nil

    assert Cookies.caller_cookie?("https://www.example.com/app.js", origin)
    refute Cookies.caller_cookie?("https://www.example.com:8443/app.js", origin)
    refute Cookies.caller_cookie?("http://www.example.com/app.js", origin)
    assert Cookies.caller_cookie?("https://cdn.example.com/app.js", site)
    refute Cookies.caller_cookie?("https://other.test/app.js", site)
    assert Cookies.caller_cookie?("https://other.test/next", %{site: page, navigation: true})
    assert Cookies.same_origin?("https://WWW.example.com/a", "https://www.example.com:443/b")
    assert Cookies.same_origin?("http://www.example.com/a", "http://www.example.com:80/b")
    refute Cookies.same_origin?("https://www.example.com/a", "http://www.example.com/a")
    refute Cookies.same_origin?("https://www.example.com/a", "https://www.example.com:8443/a")

    assert Cookies.request_navigation?(%{html_tag: "a", reference_tag: "a"})
    refute Cookies.request_navigation?(%{html_tag: "a", reference_tag: "a", page_open: false})
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
