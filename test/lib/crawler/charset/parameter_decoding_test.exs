defmodule Crawler.Charset.ParameterDecodingTest do
  use ExUnit.Case, async: true

  alias Crawler.Charset

  test "HTTP charset selection skips quoted and escaped fake declarations" do
    for header <- [
          ~S|text/html; note="a; charset=latin1; b"; charset=utf-8|,
          ~S|text/html; note="a\"; charset=latin1; b"; charset=utf-8|
        ] do
      assert Charset.decode("café", %{
               content_type: "text/html",
               headers: [{"content-type", header}]
             }) ==
               "café"
    end
  end

  test "meta content decoding and rewriting use the same real parameter" do
    for note <- [~S|"a; charset=latin1; b"|, ~S|"a\"; charset=latin1; b"|] do
      meta = "<meta http-equiv='content-type' content='text/html; note=" <> note
      source = meta <> "; charset=latin1'>caf" <> <<0xE9>>

      assert Charset.decode(source, %{content_type: "text/html"}) ==
               meta <> "; charset=utf-8'>café"

      utf8 = meta <> "; charset=utf-8'>café"
      assert Charset.decode(utf8, %{content_type: "text/html"}) == utf8
    end
  end

  test "quoted-pair labels rewrite their raw bytes and preserve unrelated quoted text" do
    source =
      ~S|<meta http-equiv='content-type' content='text/html; note="a\"; charset=latin1"; charset="lat\in1"'>caf| <>
        <<0xE9>>

    assert Charset.decode(source, %{content_type: "text/html"}) ==
             ~S|<meta http-equiv='content-type' content='text/html; note="a\"; charset=latin1"; charset="utf-8"'>café|
  end

  test "a form-feed-padded direct meta charset selects and declares UTF-8" do
    source = "<meta charset=\"\flatin1\f\">caf" <> <<0xE9>>

    assert Charset.decode(source, %{content_type: "text/html"}) ==
             ~s|<meta charset="utf-8">café|
  end

  test "opaque MIME prefixes retain every byte despite a declared charset" do
    source = <<255, 0, 65>>

    for type <- ["application/xhtml-binary", "textual/octet-stream"] do
      assert Charset.decode(source, %{
               content_type: type,
               headers: [{"content-type", type <> "; charset=latin1"}]
             }) == source
    end
  end

  test "custom text types decode text without processing HTML declarations" do
    source = ~s|<meta charset="latin1">café|
    assert Charset.decode(source, %{content_type: "text/html-template"}) == source
  end
end
