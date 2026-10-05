defmodule Crawler.Charset.ParameterBytesTest do
  use ExUnit.Case, async: true

  alias Crawler.Charset
  alias Crawler.Charset.HTML
  alias Crawler.Charset.Labels

  test "malformed parameter labels do not hide a later supported charset" do
    for label <- [<<255>>, "\"" <> <<255>> <> "\""] do
      field = "text/html; charset=" <> label <> "; charset=latin1"
      assert Labels.charset_param(field) == "latin1"
      assert Labels.http_charset([{"Content-Type", field}]) == "latin1"
    end
  end

  test "malformed unrelated values and parameter names do not hide a supported charset" do
    for prefix <- ["note=" <> <<255>>, <<255>> <> "=utf-8"] do
      assert Labels.charset_param("text/html; " <> prefix <> "; charset=latin1") == "latin1"
    end
  end

  test "malformed quoted text retains semicolon and escaped-quote boundaries" do
    note = ~S|"a\"; charset=latin1; | <> <<255>> <> ~S|"|
    assert Labels.charset_param("text/html; note=" <> note <> "; charset=utf-8") == "utf-8"
    assert Labels.charset_param("text/html; note=" <> note) == nil
  end

  test "HTTP decoding uses the supported parameter after a malformed label" do
    field = "text/html; charset=" <> <<255>> <> "; charset=latin1"

    assert Charset.decode("caf" <> <<0xE9>>, %{
             content_type: "text/html",
             headers: [{"content-type", field}]
           }) == "café"
  end

  test "meta content uses the supported parameter after a malformed label" do
    source =
      ~s|<meta http-equiv="content-type" content="text/html; charset=| <>
        <<255>> <> ~s|; charset=latin1">caf| <> <<0xE9>>

    assert HTML.charset(source) == "latin1"

    assert Charset.decode(source, %{content_type: "text/html"}) ==
             ~s|<meta http-equiv="content-type" content="text/html; charset=utf-8; charset=latin1">café|
  end
end
