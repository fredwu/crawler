defmodule Crawler.Charset.HTMLTest do
  use ExUnit.Case, async: true

  alias Crawler.Charset

  test "ignores meta text inside single- and double-quoted attributes" do
    for prefix <- [
          ~s(<div data-template='<meta charset="iso-8859-1">'></div>),
          ~s(<div data-template="<meta charset='iso-8859-1'>"></div>)
        ] do
      assert decode(prefix <> "café") == prefix <> "café"
    end
  end

  test "uses a real meta declaration after a quoted attribute with fake meta text" do
    prefix = ~s(<div data-template='<meta charset="utf-8">'></div>)
    body = prefix <> ~s(<meta charset="latin1">caf) <> <<0xE9>>
    assert decode(body) == prefix <> ~s(<meta charset="utf-8">café)
  end

  test "does not rewrite fake meta text when an HTTP charset selects the encoding" do
    prefix = ~s(<div data-template='<meta charset="iso-8859-1">'></div>)
    assert decode(prefix <> "caf" <> <<0xE9>>, "latin1") == prefix <> "café"
  end

  test "ignores meta text in script and style content" do
    for prefix <- [
          ~s(<script>const template = '<meta charset="iso-8859-1">';</script>),
          ~s(<style>p::before { content: '<meta charset="iso-8859-1">'; }</style>),
          ~s(<SCRIPT data-note=">">const template = '<meta charset="latin1">';</SCRIPT>)
        ] do
      assert decode(prefix <> "café") == prefix <> "café"
    end
  end

  test "continues to a real meta after a raw text closing tag" do
    for prefix <- [
          ~s(<script>const template = '<meta charset="utf-8">';</script>),
          ~s(<style>p::before { content: '<meta charset="utf-8">'; }</style>)
        ] do
      body = prefix <> ~s(<meta charset="latin1">caf) <> <<0xE9>>
      assert decode(body) == prefix <> ~s(<meta charset="utf-8">café)
    end
  end

  test "literal script text in a title or textarea does not hide the later charset" do
    for tag <- ["title", "textarea", "TITLE", "TEXTAREA"] do
      literal = ~s(<#{tag}>literal <script> and <meta charset="shift_jis"></#{tag}>)

      body =
        literal <>
          ~s(<meta charset="latin1"><a href="caf) <> <<0xE9>> <> ~s(">caf) <> <<0xE9>> <> ~s(</a>)

      assert decode(body) == literal <> ~s(<meta charset="utf-8"><a href="café">café</a>)
    end
  end

  test "unconditional raw text elements keep literal tags opaque until their real close" do
    for tag <- ["xmp", "iframe", "noembed", "noframes"] do
      literal = ~s(<#{tag}>literal <script><meta charset="shift_jis"></#{tag}>)

      body =
        literal <>
          ~s(<meta charset="latin1"><a href="caf) <> <<0xE9>> <> ~s(">caf) <> <<0xE9>> <> ~s(</a>)

      assert decode(body) == literal <> ~s(<meta charset="utf-8"><a href="café">café</a>)
    end
  end

  test "plaintext content remains literal through the end of the document" do
    body = ~s(<plaintext>literal </plaintext><meta charset="latin1">café)
    assert decode(body) == body
  end

  test "a raw text close-name prefix does not expose fake meta text" do
    prefix = ~s(<script></script-template><meta charset="latin1"></script>)
    assert decode(prefix <> "café") == prefix <> "café"
  end

  test "an unclosed script or style keeps its meta text unchanged" do
    for prefix <- [~s(<script><meta charset="latin1">), ~s(<style><meta charset="latin1">)] do
      assert decode(prefix <> "café") == prefix <> "café"
    end
  end

  test "normalizes an unsupported meta charset after HTTP decoding" do
    body = ~s(<meta charset="shift_jis">café)
    assert decode(body, "utf-8") == ~s(<meta charset="utf-8">café)
  end

  test "normalizes an unsupported meta charset after BOM decoding" do
    body = <<0xEF, 0xBB, 0xBF>> <> ~s(<meta charset="shift_jis">café)
    assert decode(body, "latin1") == ~s(<meta charset="utf-8">café)
  end

  test "normalizes an unsupported HTTP-equivalent meta charset" do
    body = ~s(<meta http-equiv="Content-Type" content="text/html; charset=shift_jis">café)

    assert decode(body, "utf-8") ==
             ~s(<meta http-equiv="Content-Type" content="text/html; charset=utf-8">café)
  end

  test "an unsupported meta label does not prevent a later supported label from selecting input" do
    body = ~s(<meta charset="shift_jis"><meta charset="latin1">caf) <> <<0xE9>>
    assert decode(body) == ~s(<meta charset="utf-8"><meta charset="utf-8">café)
  end

  test "normalizes the XML encoding after decoding UTF-16 XHTML in either byte order" do
    text = ~s(<?xml version="1.0" encoding="UTF-16"?><html><body>café</body></html>)
    expected = ~s(<?xml version="1.0" encoding="utf-8"?><html><body>café</body></html>)

    for {bom, endian} <- [{<<0xFE, 0xFF>>, :big}, {<<0xFF, 0xFE>>, :little}] do
      body = bom <> :unicode.characters_to_binary(text, :utf8, {:utf16, endian})
      assert decode(body, "latin1", "application/xhtml+xml") == expected
    end
  end

  test "normalizes an unsupported XML encoding after HTTP decoding" do
    body = ~s(<?xml version='1.0' encoding='shift_jis'?><html>café</html>)

    assert decode(body, "utf-8", "application/xhtml+xml") ==
             ~s(<?xml version='1.0' encoding='utf-8'?><html>café</html>)
  end

  test "preserves XML processing instructions and declarations without an encoding" do
    for body <- [
          ~s(<?xml-stylesheet encoding="latin1" href="style.css"?><html>café</html>),
          ~s(<?xml version="1.0"?><html>café</html>),
          ~s(<?xml version="1.0" encoding="latin1"),
          ~s(<?xml version="1.0"?><html data-note='encoding="latin1"'>café</html>)
        ] do
      assert decode(body, "utf-8", "application/xhtml+xml") == body
    end
  end

  test "limits XML declaration normalization to XHTML responses" do
    body = ~s(<?xml version="1.0" encoding="latin1"?><html>café</html>)
    assert decode(body, "utf-8", "text/html") == body
  end

  test "keeps a URL containing charset text opaque before the real charset attribute" do
    for unrelated <- [
          "data-url=https://example.com/charset=bogus",
          "data-url=https://example.com/path;charset=bogus",
          ~s(data-url="https://example.com/charset=bogus"),
          ~s(data-url='https://example.com/charset=bogus')
        ] do
      body = ~s(<meta #{unrelated} charset="shift_jis">café)
      assert decode(body, "utf-8") == ~s(<meta #{unrelated} charset="utf-8">café)
    end
  end

  test "keeps a URL containing content text opaque before the real content attribute" do
    unrelated = "data-url=https://example.com/content=bogus"

    body =
      ~s(<meta #{unrelated} http-equiv="Content-Type" content="text/html; charset=shift_jis">café)

    assert decode(body, "utf-8") ==
             ~s(<meta #{unrelated} http-equiv="Content-Type" content="text/html; charset=utf-8">café)
  end

  test "rewrites only the actual charset parameter in a content-type declaration" do
    for unrelated <- [
          "source=https://example.com/charset=bogus",
          "source=https://example.com/content=bogus",
          ~s(source='note; charset=bogus')
        ] do
      body =
        ~s(<meta http-equiv="Content-Type" content="text/html; #{unrelated}; charset=shift_jis; other=unchanged">café)

      assert decode(body, "utf-8") ==
               ~s(<meta http-equiv="Content-Type" content="text/html; #{unrelated}; charset=utf-8; other=unchanged">café)
    end
  end

  test "preserves charset parameter quoting and unrelated content-type parameters" do
    body =
      ~s(<meta http-equiv="Content-Type" content="text/html; other=unchanged; charset = 'shift_jis' ; last=value">café)

    assert decode(body, "utf-8") ==
             ~s(<meta http-equiv="Content-Type" content="text/html; other=unchanged; charset = 'utf-8' ; last=value">café)
  end

  test "decodes a declaration-only Latin-1 XHTML body and reference before normalization" do
    declaration = ~s(<?xml version="1.0" encoding="ISO-8859-1"?>)

    body =
      declaration <>
        ~s(<html><a href="caf) <> <<0xE9>> <> ~s(">caf) <> <<0xE9>> <> ~s(</a></html>)

    assert decode(body, nil, "application/xhtml+xml") ==
             ~s(<?xml version="1.0" encoding="utf-8"?><html><a href="café">café</a></html>)
  end

  test "an HTTP charset wins over a conflicting XHTML XML declaration" do
    body = ~s(<?xml version='1.0' encoding='latin1'?><html>café</html>)

    assert decode(body, "utf-8", "application/xhtml+xml") ==
             ~s(<?xml version='1.0' encoding='utf-8'?><html>café</html>)
  end

  test "a BOM wins over conflicting HTTP and XHTML XML declarations" do
    body = <<0xEF, 0xBB, 0xBF>> <> ~s(<?xml version="1.0" encoding="latin1"?><html>café</html>)

    assert decode(body, "latin1", "application/xhtml+xml") ==
             ~s(<?xml version="1.0" encoding="utf-8"?><html>café</html>)
  end

  test "the XHTML XML declaration wins over a conflicting meta charset" do
    body =
      ~s(<?xml version="1.0" encoding="latin1"?><html><meta charset="utf-8">caf) <>
        <<0xE9>> <> ~s(</html>)

    assert decode(body, nil, "application/xhtml+xml") ==
             ~s(<?xml version="1.0" encoding="utf-8"?><html><meta charset="utf-8">café</html>)
  end

  test "an unsupported XHTML XML encoding falls back to UTF-8" do
    body = ~s(<?xml version="1.0" encoding="unsupported"?><html>café</html>)

    assert decode(body, nil, "application/xhtml+xml") ==
             ~s(<?xml version="1.0" encoding="utf-8"?><html>café</html>)
  end

  test "requires a complete leading XML declaration for XHTML encoding selection" do
    for prefix <- [
          ~s( <?xml version="1.0" encoding="latin1"?>),
          ~s(<html><?xml version="1.0" encoding="latin1"?>),
          ~s(<?xml-stylesheet encoding="latin1"?>),
          ~s(<?xml version='encoding="latin1"'?>),
          ~s(<?xml version="1.0" encoding="latin1")
        ] do
      assert decode(prefix <> "caf" <> <<0xE9>>, nil, "application/xhtml+xml") ==
               prefix <> "caf�"
    end
  end

  test "bounds XHTML XML declaration encoding selection to the first 1024 bytes" do
    fixed = ~s(<?xml version="1.0" encoding="latin1"?>)
    padding = String.duplicate(" ", 1024 - byte_size(fixed))
    within = ~s(<?xml version="1.0"#{padding} encoding="latin1"?>)
    past = ~s(<?xml version="1.0"#{padding}  encoding="latin1"?>)
    assert byte_size(within) == 1024

    assert decode(within <> "caf" <> <<0xE9>>, nil, "application/xhtml+xml") ==
             String.replace(within, "latin1", "utf-8") <> "café"

    assert decode(past <> "caf" <> <<0xE9>>, nil, "application/xhtml+xml") ==
             String.replace(past, "latin1", "utf-8") <> "caf�"
  end

  test "does not use XML encoding declarations to select ordinary HTML input encoding" do
    declaration = ~s(<?xml version="1.0" encoding="latin1"?>)
    assert decode(declaration <> "caf" <> <<0xE9>>) == declaration <> "caf�"
  end

  defp decode(body, header_label \\ nil, content_type \\ "text/html") do
    header =
      if header_label, do: content_type <> "; charset=" <> header_label, else: content_type

    Charset.decode(body, %{content_type: content_type, headers: [{"content-type", header}]})
  end
end
