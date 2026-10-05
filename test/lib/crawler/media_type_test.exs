defmodule Crawler.MediaTypeTest do
  use ExUnit.Case, async: true

  alias Crawler.MediaType

  test "matches the complete HTML and XHTML media types" do
    for type <- ["text/html", " TEXT/HTML ; charset=utf-8", "application/xhtml+xml"] do
      assert MediaType.html?(type)
    end

    assert MediaType.xhtml?(" Application/XHTML+XML; charset=utf-8 ")
    refute MediaType.xhtml?("text/html")

    for type <- ["text/html-template", "application/xhtml", "application/xhtml-binary"] do
      refute MediaType.html?(type)
      refute MediaType.xhtml?(type)
    end
  end

  test "requires the text top-level type separator" do
    for type <- ["text/plain", " TEXT/CUSTOM ; charset=latin1", "text/html-template"] do
      assert MediaType.text?(type)
    end

    for type <- ["text", "textual/octet-stream", "textx/plain", "application/xhtml-binary"] do
      refute MediaType.text?(type)
    end
  end

  test "retains parameter stripping and the missing-type default" do
    assert MediaType.normalize(" Text/HTML ; note=\"a;b\"") == "text/html"
    assert MediaType.normalize(nil) == "text/html"
    assert MediaType.html?(nil)
    assert MediaType.text?(nil)
    refute MediaType.xhtml?(nil)
    assert MediaType.css?(" Text/CSS ; charset=utf-8")
    assert MediaType.javascript?(" Application/JavaScript ; charset=utf-8")
  end

  test "recognizes the complete JavaScript MIME essence set" do
    for type <- ~w(
          application/ecmascript application/javascript application/x-ecmascript
          application/x-javascript text/ecmascript text/javascript text/javascript1.0
          text/javascript1.1 text/javascript1.2 text/javascript1.3 text/javascript1.4
          text/javascript1.5 text/jscript text/livescript text/x-ecmascript text/x-javascript
        ) do
      assert MediaType.javascript?(type)
      assert MediaType.javascript?(" " <> String.upcase(type) <> "; charset=utf-8 ")
    end
  end

  test "does not classify neighboring names or data types as JavaScript" do
    for type <- ~w(
          application/json application/ld+json application/javascript1.0
          text/javascript1.6 text/javascript-template text/x-javascript-binary
          textual/javascript application/x-ecmascript-binary
        ) do
      refute MediaType.javascript?(type)
    end
  end
end
