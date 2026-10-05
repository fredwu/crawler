defmodule Crawler.URLMergeTest do
  use ExUnit.Case, async: true

  alias Crawler.HTTP
  alias Crawler.Linker
  alias Crawler.Parser.LinkParser
  alias Crawler.URL

  test "resolves mixed encoded and literal dot segments against the base directory" do
    base = "http://host/a/b/page"

    for parent <- ["..", ".%2e", ".%2E", "%2e.", "%2E.", "%2e%2e", "%2E%2E", "%2e%2E"],
        dot <- [".", "%2e", "%2E"],
        reference <- ["#{parent}/../target", "../#{parent}/target", "#{dot}/#{parent}/../target"] do
      assert URL.resolve(reference, base) == {:ok, "http://host/target"}
      assert URL.resolve(reference, base) == URL.resolve("/a/b/#{reference}", base)
      assert URL.resolve(reference, base) == URL.resolve("http://host/a/b/#{reference}", nil)
    end

    assert URL.resolve("%2e%2e/../target", "http://host/a/page") ==
             {:ok, "http://host/target"}

    assert URL.resolve("%2e%2e/../../%2E%2e/target", base) == {:ok, "http://host/target"}
    assert URL.resolve("x/%2e%2e/../target", base) == {:ok, "http://host/a/target"}
  end

  test "preserves directory endings and repeated slashes after resolving encoded dots" do
    base = "http://host/a/b/page"

    for {reference, path} <- [
          {"%2e", "/a/b/"},
          {"%2e%2e", "/a/"},
          {"%2e%2e/..", "/"},
          {"%2e%2e/../target//", "/target//"},
          {"x//%2e", "/a/b/x//"},
          {"x//%2e%2e", "/a/b/x/"},
          {"x/%2e%2e//", "/a/b//"}
        ] do
      assert URL.resolve(reference, base) == {:ok, "http://host" <> path}
      assert URL.resolve(reference, base) == URL.resolve("http://host/a/b/#{reference}", nil)
    end
  end

  test "keeps reserved path escapes and query identities when resolving parents" do
    base = "http://host/a/page?original=1"

    assert URL.resolve("%2e%2e/../a%2Fb", base) == {:ok, "http://host/a%2fb"}
    assert URL.resolve("%2e%2e/../a/b", base) == {:ok, "http://host/a/b"}
    assert URL.resolve("a%2Fb/%2e%2e/../target", base) == {:ok, "http://host/target"}
    assert URL.resolve("a/b/%2e%2e/../target", base) == {:ok, "http://host/a/target"}

    assert URL.resolve("%2e%2e/../target?x=%2e%2e/../&y=%2F#part%2Ftwo", base) ==
             {:ok, "http://host/target?x=../../&y=%2f"}

    assert URL.resolve("%2e%2e/../target?", base) == {:ok, "http://host/target?"}
    assert URL.resolve("%2e%2e/../target", base) == {:ok, "http://host/target"}
    assert URL.resolve("?", base) == {:ok, "http://host/a/page?"}
    assert URL.resolve("#part%2Ftwo", base) == {:ok, base}
  end

  test "discovers the same target for relative and absolute encoded-dot links" do
    base = "http://host/a/page"
    reference = "%2e%2e/../target?x=%2F#part"
    target = "http://host/target?x=%2f"
    opts = %{referrer_url: base, assets: []}

    for link <- [reference, "http://host/a/#{reference}"] do
      assert LinkParser.parse(
               {"a", [{"href", link}], []},
               opts,
               fn element, _opts -> element end
             ) == {"link", link, "href", target}
    end
  end

  test "offline links use the resolved path and retain the source fragment" do
    base = "http://host/a/page"
    reference = "%2e%2e/../a%2Fb?x=%2F#part%2Ftwo"
    target = "http://host/a%2fb?x=%2f#part%2Ftwo"

    assert Linker.offline_url(base, reference) == Linker.offline_url(base, target)
    assert Linker.offline_link(base, reference) == Linker.offline_link(base, target)
    assert URI.parse(Linker.offline_link(base, reference)).fragment == "part%2Ftwo"

    refute Linker.offline_link(base, reference) ==
             Linker.offline_link(base, "http://host/a/b?x=%2f#part%2Ftwo")

    refute Linker.offline_link(base, "%2e%2e/../target?") ==
             Linker.offline_link(base, "%2e%2e/../target")
  end

  test "redirect filters and requests receive the resolved encoded-dot target" do
    owner = self()
    root = "http://host/a/page"

    for {location, target} <- [
          {"%2e%2e/../target", "http://host/target"},
          {"%2E./../a%2Fb?", "http://host/a%2fb?"},
          {"../.%2e/target?x=%2F#part", "http://host/target?x=%2f"}
        ] do
      adapter = fn request ->
        url = URI.to_string(request.url)
        send(owner, {:requested, url})

        if url == root do
          {request, Req.Response.new(status: 302, headers: [{"location", location}])}
        else
          {request, Req.Response.new(status: 200, body: "TARGET")}
        end
      end

      allow = fn url ->
        send(owner, {:allowed, url})
        url == target
      end

      assert {:ok, %Req.Response{body: "TARGET", private: %{crawler_url: ^target}}} =
               HTTP.get(root, [], [adapter: adapter, retry: false], allow)

      assert_received {:requested, ^root}
      assert_received {:allowed, ^target}
      assert_received {:requested, ^target}
      refute_received {:requested, _url}
      refute_received {:allowed, _url}
    end
  end
end
