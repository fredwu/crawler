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

  test "the jar value replaces the same cookie name from the user header" do
    assert pairs(Cookies.merge_header("session=old; extra=1", "session=new")) == %{
             "session" => "new",
             "extra" => "1"
           }

    assert Cookies.merge_header("session=old", nil) == "session=old"
    assert Cookies.merge_header(nil, nil) == nil
  end

  defp pairs(nil), do: %{}

  defp pairs(header) do
    Map.new(String.split(header, ";"), fn piece ->
      [name, value] = piece |> String.trim() |> String.split("=", parts: 2)
      {name, value}
    end)
  end
end
