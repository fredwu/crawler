defmodule Crawler.Parser.JavascriptMimeTest do
  use ExUnit.Case, async: true

  alias Crawler.Charset
  alias Crawler.Parser

  @page "http://example.com/dir/page"
  @javascript ~w(
    application/ecmascript application/javascript application/x-ecmascript
    application/x-javascript text/ecmascript text/javascript text/javascript1.0
    text/javascript1.1 text/javascript1.2 text/javascript1.3 text/javascript1.4
    text/javascript1.5 text/jscript text/livescript text/x-ecmascript text/x-javascript
  )

  test "all JavaScript MIME essences select external and inline script sources" do
    for type <- @javascript do
      source =
        ~s|<script type=" \t#{String.upcase(type)}\f " language="json" src="external.js">import('./ignored.js');</script>| <>
          ~s|<script type="#{type}">import('./chunk.js');</script>|

      assert links(source, "text/html") == [
               "http://example.com/dir/external.js",
               "http://example.com/dir/chunk.js"
             ]
    end
  end

  test "language aliases still apply only when type is absent" do
    for language <- ~w(
          ecmascript javascript1.0 javascript1.1 javascript1.2 javascript1.3
          javascript1.4 javascript1.5 jscript livescript x-ecmascript x-javascript
        ) do
      source =
        ~s|<script language="#{String.upcase(language)}" src="external.js"></script>| <>
          ~s|<script language="#{language}">import('./chunk.js');</script>| <>
          ~s|<script type="application/json" language="#{language}" src="ignored.js"></script>|

      assert links(source, "text/html") == [
               "http://example.com/dir/external.js",
               "http://example.com/dir/chunk.js"
             ]
    end
  end

  test "JavaScript MIME parameters select external and inline script sources" do
    for type <- @javascript do
      parameterized = type <> "; charset=utf-8"

      source =
        ~s|<script type="#{parameterized}" language="javascript" src="external.js">import('./ignored.js');</script>| <>
          ~s|<script type="#{parameterized}">import('./chunk.js');</script>|

      assert links(source, "text/html") == [
               "http://example.com/dir/external.js",
               "http://example.com/dir/chunk.js"
             ]
    end
  end

  test "non-ASCII script type padding and non-script parameters are not executable" do
    for type <- @javascript do
      padded = "\u00A0" <> type <> "\u00A0"

      source =
        ~s|<script type="#{padded}" language="javascript" src="ignored.js">import('./ignored.js');</script>| <>
          ~s|<script type="#{padded}">import('./ignored.js');</script>|

      assert links(source, "text/html") == []
    end

    source =
      ~s|<script type="module;charset=utf-8" src="ignored.js">import('./ignored.js');</script>| <>
        ~s|<script type="application/json" src="ignored.js">import('./ignored.js');</script>|

    assert links(source, "text/html") == []
  end

  test "all JavaScript response aliases retain charset conversion and dependency parsing" do
    for type <- @javascript do
      source = ~s|const label='caf| <> <<0xE9>> <> ~s|'; import('./chunk.js');|
      field = type <> "; charset=latin1"

      decoded =
        Charset.decode(source, %{content_type: field, headers: [{"content-type", field}]})

      assert decoded == ~s|const label='café'; import('./chunk.js');|
      assert links(decoded, field) == ["http://example.com/dir/chunk.js"]
    end
  end

  defp links(source, type) do
    source
    |> Parser.parse_links(
      %{url: @page, content_type: type, html_tag: "a", assets: ["js"]},
      fn
        {_, url}, _opts -> url
        {_, _raw, _attr, url}, _opts -> url
      end
    )
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end
end
