defmodule Crawler.HTTP.DocumentHeadersTest do
  use ExUnit.Case, async: true

  alias Crawler.HTTP.DocumentHeaders

  test "refresh and link headers become the same elements as the tags" do
    headers = [
      {"Refresh", "0; url=/next"},
      {"refresh", "0; url=/after"},
      {"link", "</app.css>; rel=\"stylesheet\", </extra.css>; rel=\"stylesheet\""},
      {"Link", "</icon.png>; rel=\"icon\""}
    ]

    assert DocumentHeaders.elements(headers) == [
             {"meta", [{"http-equiv", "refresh"}, {"content", "0; url=/next"}], []},
             {"meta", [{"http-equiv", "refresh"}, {"content", "0; url=/after"}], []},
             {"link", [{"rel", "stylesheet"}, {"href", "/app.css"}], []},
             {"link", [{"rel", "stylesheet"}, {"href", "/extra.css"}], []},
             {"link", [{"rel", "icon"}, {"href", "/icon.png"}], []}
           ]
  end

  test "commas inside quotes or a link uri stay in that value" do
    headers = [
      {"link",
       "</app.css>; rel=\"stylesheet\"; title=\"a, b\", <https://example.com/a,b>; rel=stylesheet"}
    ]

    assert DocumentHeaders.elements(headers) == [
             {"link", [{"rel", "stylesheet"}, {"href", "/app.css"}], []},
             {"link", [{"rel", "stylesheet"}, {"href", "https://example.com/a,b"}], []}
           ]
  end

  test "preload parameters stay on the link element" do
    headers = [
      {"link", ~s|</app.css>; rel=preload; title=main; as=style|},
      {"Link", ~s|</hero.png>; REL="preload"; AS="image"; imagesrcset="a.png 1x, b.png 2x"|}
    ]

    assert DocumentHeaders.elements(headers) == [
             {"link", [{"rel", "preload"}, {"href", "/app.css"}, {"as", "style"}], []},
             {"link",
              [
                {"rel", "preload"},
                {"href", "/hero.png"},
                {"as", "image"},
                {"imagesrcset", "a.png 1x, b.png 2x"}
              ], []}
           ]
  end

  test "link parameter names are matched without changing their values" do
    headers = [{"link", ~s|</app.css>; AS=Style|}]

    assert DocumentHeaders.elements(headers) == []

    headers = [{"link", ~s|</app.css>; REL=preload; AS=Style|}]

    assert DocumentHeaders.elements(headers) == [
             {"link", [{"rel", "preload"}, {"href", "/app.css"}, {"as", "Style"}], []}
           ]
  end
end
