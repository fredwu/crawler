defmodule Crawler.Charset.HTMLForeignEndTest do
  use ExUnit.Case, async: true

  alias Crawler.Charset
  alias Crawler.Charset.HTMLScanner

  for foreign <- ["svg", "math"], closing <- ["p", "br"] do
    test "#{foreign} </#{closing}> keeps a literal script charset from selecting Latin-1" do
      source =
        "<#{unquote(foreign)}></#{unquote(closing)}><script/>" <>
          ~s|<meta charset="latin1"><a href="next">café</a>|

      assert HTMLScanner.meta_spans(source) == []
      assert Charset.decode(source, %{content_type: "text/html"}) == source
    end

    test "#{foreign} </#{closing}> exposes the real charset after the script closes" do
      prefix =
        "<#{unquote(foreign)}></#{unquote(closing)}><script/>" <>
          ~s|<meta charset="utf-8"></script>|

      source = prefix <> ~s|<meta charset="latin1"><p>caf| <> <<0xE9>> <> "</p>"
      expected = prefix <> ~s|<meta charset="utf-8"><p>café</p>|

      assert HTMLScanner.meta_spans(source) == [{byte_size(prefix), 23}]
      assert Charset.decode(source, %{content_type: "text/html"}) == expected
    end
  end
end
