defmodule Crawler.Charset.CSSTest do
  use ExUnit.Case, async: true

  alias Crawler.Charset

  @latin1_selector "#caf" <> <<0xE9>> <> " { color: red; }"
  @utf8_selector "#café { color: red; }"
  @utf8_declaration ~s(@charset "utf-8";)

  test "transcodes an HTTP-declared stylesheet and normalizes its leading declaration" do
    body = ~s(@charset "utf-8";) <> @latin1_selector
    assert decode(body, "iso-8859-1") == @utf8_declaration <> @utf8_selector
  end

  test "an HTTP charset wins over a conflicting CSS declaration" do
    body = ~s(@charset "iso-8859-1";) <> @utf8_selector
    assert decode(body, "utf-8") == @utf8_declaration <> @utf8_selector
  end

  test "uses the leading CSS declaration when HTTP supplies no supported charset" do
    body = ~s(@charset "ISO-8859-1";) <> @latin1_selector

    for header_label <- [nil, "unsupported"] do
      assert decode(body, header_label) == @utf8_declaration <> @utf8_selector
    end
  end

  test "a UTF-8 BOM wins over HTTP and CSS charset declarations" do
    body = <<0xEF, 0xBB, 0xBF>> <> ~s(@charset "iso-8859-1";) <> @utf8_selector
    assert decode(body, "iso-8859-1") == @utf8_declaration <> @utf8_selector
  end

  test "decodes both UTF-16 BOM byte orders before normalizing the CSS declaration" do
    for {bom, endian} <- [{<<0xFE, 0xFF>>, :big}, {<<0xFF, 0xFE>>, :little}] do
      text = ~s(@charset "latin1";) <> @utf8_selector
      body = bom <> :unicode.characters_to_binary(text, :utf8, {:utf16, endian})
      assert decode(body, "latin1") == @utf8_declaration <> @utf8_selector
    end
  end

  test "preserves UTF-16 decoding selected by an HTTP charset without a BOM" do
    for {label, endian} <- [{"utf-16be", :big}, {"utf-16le", :little}] do
      text = ~s(@charset "latin1";) <> @utf8_selector
      body = :unicode.characters_to_binary(text, :utf8, {:utf16, endian})
      assert decode(body, label) == @utf8_declaration <> @utf8_selector
    end
  end

  test "a UTF-16 CSS label falls back to UTF-8 without a BOM or HTTP charset" do
    for label <- ["utf-16", "utf-16be", "utf-16le"] do
      body = ~s(@charset "#{label}";) <> @utf8_selector
      assert decode(body) == @utf8_declaration <> @utf8_selector
    end
  end

  test "normalizes an unknown leading declaration after the UTF-8 fallback" do
    body = ~s(@charset "unsupported";) <> @utf8_selector
    assert decode(body) == @utf8_declaration <> @utf8_selector
  end

  test "ignores declarations that do not have the exact leading byte sequence" do
    for prefix <- [
          ~s( @charset "latin1";),
          ~s(/* comment */ @charset "latin1";),
          ~s(@CHARSET "latin1";),
          ~s(@charset 'latin1';),
          "@charset\t\"latin1\";",
          ~s(@charset "latin1" ;),
          ~s(@charset "latin1),
          ~s(@charset "latin1"extra";),
          ~s(@charset "é";),
          ~s(p::before { content: '@charset "latin1";'; })
        ] do
      assert decode(prefix <> @latin1_selector) == prefix <> "#caf� { color: red; }"
    end
  end

  test "recognizes a declaration through byte 1024 and ignores one that ends after it" do
    within = ~s(@charset "latin1#{String.duplicate(" ", 1006)}";)
    past = ~s(@charset "latin1#{String.duplicate(" ", 1007)}";)
    assert byte_size(within) == 1024
    assert decode(within <> @latin1_selector) == @utf8_declaration <> @utf8_selector
    assert decode(past <> @latin1_selector) == past <> "#caf� { color: red; }"
  end

  defp decode(body, header_label \\ nil) do
    header = if header_label, do: "text/css; charset=" <> header_label, else: "text/css"
    Charset.decode(body, %{content_type: "text/css", headers: [{"content-type", header}]})
  end
end
