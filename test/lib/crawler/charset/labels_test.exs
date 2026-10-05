defmodule Crawler.Charset.LabelsTest do
  use ExUnit.Case, async: true

  alias Crawler.Charset.Labels
  alias Crawler.Charset.Parameters

  test "ignores supported charset labels inside unrelated quoted parameters" do
    for note <- [
          ~S|"a; charset=latin1; b"|,
          ~S|"a\"; charset=latin1; b"|,
          ~S|"a\\\"; charset=latin1; b"|
        ] do
      assert Labels.charset_param("text/html; note=" <> note <> "; charset=utf-8") == "utf-8"
      assert Labels.charset_param("text/html; note=" <> note) == nil
    end
  end

  test "an apostrophe in an unquoted parameter does not hide the next charset" do
    assert Labels.charset_param("text/html; note=can't; charset=latin1") == "latin1"
  end

  test "decodes quoted pairs without changing source offsets" do
    source = ~S|text/html; note="a\"; charset=latin1"; charset="utf\-8" |
    assert Labels.charset_param(source) == "utf-8"

    {start, finish} = Parameters.find_value(source, "charset")
    assert binary_part(source, start, finish - start) == ~S|utf\-8|
  end

  test "retains the first supported charset and ignores empty or unknown labels" do
    assert Labels.charset_param("text/html; charset=; charset=unknown; CHARSET=latin1") ==
             "latin1"

    assert Labels.charset_param("text/html; charset=latin1; charset=utf-8") == "latin1"
    assert Labels.charset_param("text/html") == nil
    assert Labels.charset_param(<<255>>) == nil
  end

  test "trims all encoding ASCII whitespace including form feed" do
    for whitespace <- [" ", "\t", "\n", "\f", "\r"] do
      assert Labels.normalize(whitespace <> "LATIN1" <> whitespace) == "latin1"
      assert Labels.normalize(whitespace) == nil
    end

    assert Labels.normalize("\vlatin1\v") == "\vlatin1\v"
    assert Labels.normalize("\u00A0latin1\u00A0") == "\u00A0latin1\u00A0"
  end

  test "invalid UTF-8 labels do not become supported UTF-8 declarations" do
    for bytes <- [<<255>>, <<0xC3>>, <<0xC0, 0xAF>>, "utf-8" <> <<255>>] do
      assert Labels.normalize(bytes) == nil
      assert Labels.normalize("\f\"" <> bytes <> "\"\f") == nil
      refute Labels.known?(Labels.normalize(bytes))
    end
  end

  test "literal quotes in extracted labels remain unsupported" do
    for quote <- ["\"", "'"],
        label <- [quote <> "latin1", "latin1" <> quote, quote <> "latin1" <> quote] do
      assert Labels.normalize("\f" <> label <> "\f") == label
      refute Labels.known?(Labels.normalize(label))
    end
  end
end
