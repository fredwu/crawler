defmodule Crawler.Parser.HtmlParserTest do
  use Crawler.TestCase, async: true

  alias Crawler.Parser.HtmlParser

  doctest HtmlParser

  test "finds script tags that omit type='text/javascript'" do
    html = """
    <script src="/app.js"></script>
    <script type="module" src="/mod.js"></script>
    <script type="text/javascript">inline</script>
    """

    assert [
             {"script", [{"src", "/app.js"}], _app},
             {"script", [{"type", "module"}, {"src", "/mod.js"}], _mod}
           ] = HtmlParser.parse(html, %{assets: ["js"]})
  end
end
