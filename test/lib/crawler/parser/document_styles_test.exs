defmodule Crawler.Parser.DocumentStylesTest do
  use ExUnit.Case, async: false

  import Crawler.TestHelpers, only: [unique_scope: 1]

  alias Crawler.Parser
  alias Crawler.Parser.CssParser.DocumentStyles
  alias Crawler.Parser.CssParser.Scanner
  alias Crawler.Parser.CssParser.Variables
  alias Crawler.Parser.CssSheets
  alias Crawler.Snapper.LinkReplacer
  alias Crawler.Store

  @url "http://standalone.test/dir/page"

  for scoped? <- [false, true] do
    test "standalone document styles work with scoped options #{scoped?} and no state owner" do
      opts = options()
      opts = if unquote(scoped?), do: Map.put(opts, :scope, unique_scope("pure-css")), else: opts

      html = """
      <style>:root { --first: url("first.png"); --second: url("second.png"); --idle: url("idle.png"); }</style>
      <style>body { background: var(--first); border-image: var(--second); color: var(--idle); }</style>
      """

      store = Process.whereis(Store)
      css = Process.whereis(CssSheets)
      :sys.suspend(store)
      :sys.suspend(css)

      try do
        before_store = :sys.get_state(store)
        before_css = :sys.get_state(css)

        task = Task.async(fn -> {links(html, opts), LinkReplacer.replace_links(html, opts)} end)
        on_exit(fn -> Process.exit(task.pid, :kill) end)
        assert {found, {:ok, rewritten}} = Task.await(task, 2_000)

        assert values(found) == [
                 "http://standalone.test/dir/first.png",
                 "http://standalone.test/dir/second.png"
               ]

        assert_handler_options(found, opts)

        for file <- ["first.png", "second.png"] do
          assert rewritten =~ "http://standalone.test/dir/" <> file
          refute rewritten =~ ~s|url("#{file}")|
        end

        assert rewritten =~ ~s|url("idle.png")|
        assert rewritten =~ "var(--first)"
        refute String.contains?(rewritten, <<0>>)
        assert :sys.get_state(store) == before_store
        assert :sys.get_state(css) == before_css
      after
        :sys.resume(css)
        :sys.resume(store)
      end
    end
  end

  test "srcdoc styles do not inherit the enclosing document's bindings or context" do
    opts = Map.put(options(), :scope, unique_scope("pure-srcdoc-css"))

    html = """
    <style>:root { --shared: url("outer.png"); --parent-only: url("leak.png"); } body { background: var(--shared); }</style>
    <iframe srcdoc='<style>:root { --shared: url("inner.png"); }</style><style>body { background: var(--shared); border-image: var(--parent-only); }</style>'></iframe>
    """

    found = links(html, opts)

    assert values(found) == [
             "http://standalone.test/dir/inner.png",
             "http://standalone.test/dir/outer.png"
           ]

    assert_handler_options(found, opts)
    assert {:ok, rewritten} = LinkReplacer.replace_links(html, opts)
    assert rewritten =~ "http://standalone.test/dir/outer.png"
    assert rewritten =~ "http://standalone.test/dir/inner.png"
    assert rewritten =~ ~s|url("leak.png")|
    refute rewritten =~ "http://standalone.test/dir/leak.png"
  end

  test "a reused standalone scope does not carry styles into another invocation" do
    opts = Map.put(options(), :scope, unique_scope("pure-repeat-css"))
    first = ~s|<style>:root { --bg: url("first.png"); } body { background: var(--bg); }</style>|
    assert values(links(first, opts)) == ["http://standalone.test/dir/first.png"]
    later = "<style>body { background: var(--bg); }</style>"
    assert links(later, opts) == []
    assert {:ok, ^later} = LinkReplacer.replace_links(later, opts)
    refute Map.has_key?(:sys.get_state(Store).scopes, opts.scope)
  end

  test "pre-scanned sheet construction preserves bounded graph outcomes" do
    analysis =
      Scanner.analyze(~s|:root { --bg: url("first.png"); } body { background: var(--bg); }|)

    sheet = Variables.sheet(analysis, :original, @url, 0)
    context = DocumentStyles.from_sheets([sheet])
    assert %{status: :ok, pictures: [_ | _]} = DocumentStyles.snapshot(context)
    assert [%{value: "first.png"}] = DocumentStyles.tokens(context, :original, analysis)
    limited = DocumentStyles.from_sheets([sheet], max_work: 1)
    assert %{status: {:limited, :work}} = DocumentStyles.snapshot(limited)

    assert_raise Variables.LimitError, fn ->
      DocumentStyles.tokens(limited, :original, analysis)
    end
  end

  defp links(body, opts) do
    body
    |> Parser.parse_links(opts, fn element, link_opts -> {element, link_opts} end)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp values(found) do
    found
    |> Enum.map(fn
      {{_, _, _, url}, _opts} -> url
      {{_, url}, _opts} -> url
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp assert_handler_options(found, opts) do
    for {_element, child} <- found do
      refute Map.has_key?(child, :document_styles)
      refute Map.has_key?(child, :document_style_id)
      refute Map.has_key?(child, :generation)
      assert child[:scope] == opts[:scope]
    end
  end

  defp options do
    %{
      url: @url,
      referrer_url: @url,
      depth: 1,
      max_depths: 3,
      html_tag: "a",
      content_type: "text/html",
      assets: ["css", "images"]
    }
  end
end
