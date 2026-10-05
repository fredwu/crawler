defmodule Crawler.Charset.HTMLAttributesTest do
  use ExUnit.Case, async: true

  alias Crawler.Charset

  test "the first charset attribute selects input and is the only duplicate rewritten" do
    source = ~s|<meta charset="utf-8" charset="latin1">café|
    assert decode(source) == source

    source = ~s|<meta charset="latin1" charset="utf-8">caf| <> <<0xE9>>
    assert decode(source) == ~s|<meta charset="utf-8" charset="utf-8">café|
  end

  test "a first valueless charset is not replaced by a later duplicate" do
    source = ~s|<meta charset charset="latin1">café|
    assert decode(source) == source
  end

  test "the first http-equiv attribute controls whether content declares a charset" do
    source =
      ~s|<meta http-equiv="other" http-equiv="content-type" content="text/html; charset=latin1">café|

    assert decode(source) == source

    source =
      ~s|<meta http-equiv="content-type" http-equiv="other" content="text/html; charset=latin1">caf| <>
        <<0xE9>>

    assert decode(source) ==
             ~s|<meta http-equiv="content-type" http-equiv="other" content="text/html; charset=utf-8">café|
  end

  test "the first content value selects input and is the only duplicate rewritten" do
    source =
      ~s|<meta http-equiv="content-type" content="text/html; charset=utf-8" content="text/html; charset=latin1">café|

    assert decode(source) == source

    source =
      ~s|<meta http-equiv="content-type" content="text/html; charset=latin1" content="text/html; charset=utf-8">caf| <>
        <<0xE9>>

    assert decode(source) ==
             ~s|<meta http-equiv="content-type" content="text/html; charset=utf-8" content="text/html; charset=utf-8">café|
  end

  defp decode(source), do: Charset.decode(source, %{content_type: "text/html"})
end
