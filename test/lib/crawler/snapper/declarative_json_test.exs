defmodule Crawler.Snapper.DeclarativeJsonTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker
  alias Crawler.Snapper.LinkReplacer
  alias Crawler.URL

  test "a saved manifest rewrites only its url members" do
    manifest_url = "http://example.com/app.webmanifest"

    body =
      ~s|{"name":"Demo","scope":"/","start_url":"/","icons":[{"src":"/","type":"image/png"}]}|

    assert {:ok, saved} =
             LinkReplacer.replace_links(body, manifest_opts(manifest_url, ["images"]))

    page = offline(manifest_url, "/")
    assert String.contains?(saved, ~s("name":"Demo"))
    assert String.contains?(saved, ~s("scope":"/"))
    assert String.contains?(saved, ~s("type":"image/png"))
    assert String.contains?(saved, ~s("start_url":"#{page}"))
    assert String.contains?(saved, ~s("src":"#{page}"))
    refute String.contains?(saved, ~s("start_url":"/"))
    refute String.contains?(saved, ~s("src":"/"))
  end

  test "a saved manifest leaves icon addresses when images are off" do
    manifest_url = "http://example.com/app.webmanifest"
    body = ~s|{"scope":"/","start_url":"/","icons":[{"src":"/"}]}|

    assert {:ok, saved} = LinkReplacer.replace_links(body, manifest_opts(manifest_url, []))

    page = offline(manifest_url, "/")
    assert String.contains?(saved, ~s("scope":"/"))
    assert String.contains?(saved, ~s("src":"/"))
    assert String.contains?(saved, ~s("start_url":"#{page}"))
    refute String.contains?(saved, ~s("start_url":"/"))
  end

  test "a saved rules file keeps list entries that share one raw url" do
    file_url = "http://example.com/rules/rules.json"
    document_base = "http://example.com/blog/"

    body = ~s|{"prefetch":[{"urls":["next"]},{"urls":["next"],"relative_to":"document"}]}|

    opts = %{
      fetch_kind: :speculation_rules,
      url: file_url,
      referrer_url: file_url,
      document_base: document_base
    }

    assert {:ok, saved} = LinkReplacer.replace_links(body, opts)

    file_next = offline(file_url, "next")
    {:ok, document_next} = URL.resolve("next", document_base)
    document_offline = Linker.offline_link(file_url, document_next)

    assert file_next != document_offline
    assert String.contains?(saved, ~s("#{file_next}"))
    assert String.contains?(saved, ~s("#{document_offline}"))
    refute String.contains?(saved, ~s("next"))
  end

  test "a saved inline rule rewrites its urls and leaves the other members" do
    page = "http://example.com/start"

    rules =
      ~s|{"prefetch":[{"source":"list","urls":["next"],"eagerness":"eager"},{"urls":["skip-ruleset"],"relative_to":"ruleset"}]}|

    body = """
    <html><head><base href="http://example.com/blog/"></head>
    <body>
    <a href="eager">go</a>
    <a href="list">list</a>
    <script type="speculationrules">#{rules}</script>
    </body></html>
    """

    assert {:ok, saved} =
             LinkReplacer.replace_links(body, %{
               url: page,
               referrer_url: page,
               content_type: "text/html",
               html_tag: "a",
               depth: 0,
               max_depths: 3,
               assets: []
             })

    {:ok, next} = URL.resolve("next", "http://example.com/blog/")
    next_offline = Linker.offline_link(page, next)

    assert String.contains?(saved, ~s("eagerness":"eager"))
    assert String.contains?(saved, ~s("source":"list"))
    assert String.contains?(saved, ~s("skip-ruleset"))
    assert String.contains?(saved, ~s("relative_to":"ruleset"))
    assert String.contains?(saved, ~s("#{next_offline}"))
    refute String.contains?(saved, ~s("next"))
  end

  test "an unparsed fetch preload leaves speculation rules unchanged" do
    page = "http://example.com/notes.html"
    rules = ~s|{"prefetch":[{"urls":["/soon"]}]}|

    body = """
    <base href="http://example.com/notes/">
    <a href="/secret">secret</a>
    <script type="speculationrules">#{rules}</script>
    """

    assert {:ok, saved} =
             LinkReplacer.replace_links(body, %{
               url: page,
               referrer_url: page,
               content_type: "text/html",
               html_tag: "fetch",
               depth: 1,
               max_depths: 3,
               assets: ["css"]
             })

    assert String.contains?(saved, ~s(href="http://example.com/notes/"))
    assert String.contains?(saved, ~s("/soon"))
    assert String.contains?(saved, ~s(href="/secret"))
  end

  defp manifest_opts(url, assets) do
    %{
      fetch_kind: :manifest,
      url: url,
      referrer_url: url,
      assets: assets,
      html_tag: "link",
      content_type: "application/manifest+json"
    }
  end

  defp offline(current, raw) do
    {:ok, resolved} = URL.resolve(raw, current)
    Linker.offline_link(current, resolved)
  end
end
