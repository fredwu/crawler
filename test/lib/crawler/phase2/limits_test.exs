defmodule Crawler.LimitsTest do
  use ExUnit.Case, async: true

  alias Crawler.Limits

  test "managed adapters receive explicit finite values and preserve other options" do
    opts = Limits.validate!(%{url: "http://example.test", max_xml_depth: 17, max_css_work: 21})
    assert opts.url == "http://example.test"
    assert Limits.xml(opts)[:max_depth] == 17
    assert Limits.analysis(opts).max_xml_depth == 17
    assert Limits.analysis(opts).max_xml_tokens == opts.max_xml_tokens
    assert Limits.analysis(opts).max_xml_attributes == opts.max_xml_attributes
    assert Limits.css(opts)[:max_work] == 21
    assert opts.run_timeout == 600_000
    assert Enum.all?(Limits.defaults(), fn {_key, value} -> is_integer(value) and value > 0 end)
  end

  test "resource bounds reject nonfinite, negative, nil and fractional values" do
    for key <- Map.keys(Limits.defaults()), invalid <- [:infinity, -1, nil, 1.5] do
      assert_raise ArgumentError, fn -> Limits.validate!(%{key => invalid}) end
    end

    assert Limits.validate!(%{max_body: 0}).max_body == 0

    for key <- Map.keys(Limits.defaults()) -- [:max_body] do
      assert_raise ArgumentError, fn -> Limits.validate!(%{key => 0}) end
    end
  end

  test "cookie defaults have one owner and receive the same validation" do
    cookie_defaults = %{max_cookies: 17, max_cookie_jar_bytes: 200}
    opts = Limits.validate!(%{max_cookies: 10}, cookie_defaults)
    assert Limits.cookies(opts) == %{max_cookies: 10, max_cookie_jar_bytes: 200}
    assert_raise ArgumentError, fn -> Limits.validate!(%{max_cookies: 0}, cookie_defaults) end
  end

  test "existing numeric contracts are checked without changing receive infinity" do
    assert %{timeout: :infinity, max_pages: :infinity} =
             Limits.validate!(%{timeout: :infinity, max_pages: :infinity})

    assert %{max_depths: 0, retries: 0, interval: 0, workers: 1} =
             Limits.validate!(%{max_depths: 0, retries: 0, interval: 0, workers: 1})

    for opts <- [%{timeout: -1}, %{max_pages: nil}, %{workers: 0}, %{retries: :infinity}] do
      assert_raise ArgumentError, fn -> Limits.validate!(opts) end
    end
  end
end
