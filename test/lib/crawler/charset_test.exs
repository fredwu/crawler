defmodule Crawler.CharsetTest do
  use ExUnit.Case, async: true

  alias Crawler.Charset

  test "decodes a latin-1 page as windows-1252 and lets the header win" do
    href = "caf" <> <<0xE9>>

    header = decode(href, "text/html", "text/html; charset=iso-8859-1")
    assert header == "café"

    meta = decode(~s(<meta charset="ISO-8859-1">) <> href, "text/html", "text/html")
    assert meta =~ "café"

    quoted = decode(href, "text/html", ~s(text/html; charset="latin-1"))
    assert quoted == "café"

    equiv =
      decode(
        ~s(<meta content="text/html; charset=latin1" http-equiv="Content-Type">) <> href,
        "text/html",
        "text/html"
      )

    assert equiv =~ "café"

    wins =
      decode(
        ~s(<meta charset="iso-8859-1">caf) <> <<0xC3, 0xA9>>,
        "text/html",
        "text/html; charset=utf-8"
      )

    assert wins =~ "café"
    refute wins =~ "cafÃ©"

    loses =
      decode(
        ~s(<meta charset="utf-8">) <> href,
        "text/html",
        "text/html; charset=us-ascii"
      )

    assert loses =~ "café"
  end

  test "uses a byte-order mark before the declared charset" do
    bom = <<0xEF, 0xBB, 0xBF>> <> "café"

    assert decode(bom, "text/html", "text/html; charset=iso-8859-1") == "café"

    utf16 = <<0xFF, 0xFE>> <> :unicode.characters_to_binary("café", :utf8, {:utf16, :little})
    assert decode(utf16, "text/html", "text/html; charset=iso-8859-1") == "café"

    be = :unicode.characters_to_binary("café", :utf8, {:utf16, :big})
    assert decode(be, "text/css", "text/css; charset=utf-16be") == "café"
  end

  test "maps the windows-1252 bytes that latin-1 leaves as controls" do
    euro = decode(<<0x80>>, "text/plain", "text/plain; charset=iso-8859-1")
    assert euro == "€"

    undefined = decode(<<0x81>>, "text/html", "text/html; charset=windows-1252")
    assert undefined == <<0xEF, 0xBF, 0xBD>>
  end

  test "replaces invalid utf-8 and leaves non-text bytes alone" do
    assert decode(<<0xE9>>, "text/html", "text/html; charset=utf-8") == <<0xEF, 0xBF, 0xBD>>

    assert decode(<<0x89, 0xE9>>, "image/png", "image/png; charset=iso-8859-1") ==
             <<0x89, 0xE9>>

    script = decode(<<0xE9>>, "application/javascript", "application/javascript; charset=latin1")
    assert script == "é"
  end

  test "trims whitespace around a meta charset label" do
    href = <<0xE9>>

    spaced =
      decode(~s(<meta charset=" iso-8859-1 ">) <> href, "text/html", "text/html")

    assert spaced =~ "é"

    blank_then_real =
      decode(
        ~s(<meta charset="   "><meta charset="iso-8859-1">) <> href,
        "text/html",
        "text/html"
      )

    assert blank_then_real =~ "é"
  end

  test "ignores a meta charset inside a comment" do
    commented = ~s(<!-- <meta charset="iso-8859-1"> -->) <> <<0xE9>>
    decoded = decode(commented, "text/html", "text/html")
    refute decoded =~ "é"

    real =
      decode(
        ~s(<!-- <meta charset="utf-8"> --><meta charset="iso-8859-1">) <> <<0xE9>>,
        "text/html",
        "text/html"
      )

    assert real =~ "é"
  end

  test "does not loop on a truncated utf-16 body" do
    assert decode(<<0x00, 0x61, 0xDC>>, "text/plain", "text/plain; charset=utf-16be") ==
             "a" <> <<0xEF, 0xBF, 0xBD>>

    assert decode(<<0xDC>>, "text/html", "text/html; charset=utf-16") == <<0xEF, 0xBF, 0xBD>>

    assert decode(<<0xDC, 0x00>>, "text/plain", "text/plain; charset=utf-16be") ==
             <<0xEF, 0xBF, 0xBD>>

    assert decode(<<0xDC>>, "text/plain", "text/plain; charset=utf-16le") == <<0xEF, 0xBF, 0xBD>>
  end

  test "a blank or quoted charset does not hide the encoding" do
    href = <<0xE9>>

    assert decode(href, "text/html", "text/html; charset=") =~ <<0xEF, 0xBF, 0xBD>>

    assert decode(href, "text/html", "text/html; charset=; charset=iso-8859-1") == "é"
    assert decode(href, "text/html", ~s(text/html; charset="   ")) =~ <<0xEF, 0xBF, 0xBD>>
    assert decode(href, "text/html", ~s(text/html; charset= "iso-8859-1")) == "é"
    assert decode(href, "text/html", ~s(text/html; charset="iso-8859-1" ; foo=bar)) == "é"

    blank_meta =
      decode(
        ~s(<meta http-equiv="content-type" content="text/html; charset="><meta charset="iso-8859-1">) <>
          href,
        "text/html",
        "text/html"
      )

    assert blank_meta =~ "é"

    unknown =
      decode(
        ~s(<meta charset="bogus"><meta charset="iso-8859-1">) <> href,
        "text/html",
        "text/html"
      )

    assert unknown =~ "é"
    assert unknown =~ "utf-8"
  end

  test "saves html as utf-8 and leaves a css charset rule unchanged" do
    href = <<0xE9>>
    meta = decode(~s(<meta charset="ISO-8859-1">) <> href, "text/html", "text/html")

    assert meta =~ "é"
    assert meta =~ ~s(charset="utf-8")
    refute meta =~ "ISO-8859-1"

    equiv =
      decode(
        ~s(<meta content="text/html; charset=latin1" http-equiv="Content-Type">) <> href,
        "text/html",
        "text/html"
      )

    assert equiv =~ "é"
    assert equiv =~ "charset=utf-8"
    refute equiv =~ "latin1"

    commented = decode(~s(<!-- <meta charset="iso-8859-1"> -->) <> href, "text/html", "text/html")
    assert commented =~ "iso-8859-1"
    refute commented =~ "é"

    slash = decode("<meta charset=iso-8859-1/>" <> href, "text/html", "text/html")
    refute slash =~ "é"

    css = decode(~s(@charset "iso-8859-1";) <> href, "text/css", "text/css")
    assert css =~ ~s(@charset "iso-8859-1";)
    refute css =~ "é"
  end

  test "ignores a meta charset past the prescan" do
    padding = String.duplicate(" ", 1024)
    body = padding <> ~s(<meta charset="iso-8859-1">) <> <<0xE9>>
    decoded = decode(body, "text/html", "text/html")

    refute decoded =~ "é"
    assert decoded =~ <<0xEF, 0xBF, 0xBD>>
  end

  defp decode(body, content_type, header) do
    Charset.decode(body, %{
      content_type: content_type,
      headers: [{"Content-Type", header}]
    })
  end
end
