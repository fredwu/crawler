defmodule Crawler.Charset.InvalidLabelTest do
  use ExUnit.Case, async: true

  alias Crawler.Charset
  alias Crawler.Charset.HTML

  test "a malformed direct meta label does not hide a later supported declaration" do
    source = malformed_meta() <> ~s|<meta charset="latin1">caf| <> <<0xE9>>
    assert HTML.charset(source) == "latin1"

    assert Charset.decode(source, %{content_type: "text/html"}) ==
             ~s|<meta charset="utf-8"><meta charset="utf-8">café|
  end

  test "a malformed direct label allows content on the same meta to select the encoding" do
    source =
      ~s|<meta charset="| <>
        <<255>> <>
        ~s|" http-equiv="content-type" content="text/html; charset=latin1">caf| <> <<0xE9>>

    assert HTML.charset(source) == "latin1"

    assert Charset.decode(source, %{content_type: "text/html"}) ==
             ~s|<meta charset="utf-8" http-equiv="content-type" content="text/html; charset=utf-8">café|
  end

  test "a malformed XML encoding allows XHTML to use a supported meta declaration" do
    source =
      ~s|<?xml version="1.0" encoding="| <>
        <<255>> <>
        ~s|"?><meta charset="latin1">caf| <> <<0xE9>>

    assert HTML.xml_charset(source) == nil

    assert Charset.decode(source, %{content_type: "application/xhtml+xml"}) ==
             ~s|<?xml version="1.0" encoding="utf-8"?><meta charset="utf-8">café|
  end

  test "without a supported declaration malformed input uses normal body replacement" do
    source = malformed_meta() <> "caf" <> <<0xE9>>
    assert HTML.charset(source) == nil

    assert Charset.decode(source, %{content_type: "text/html"}) ==
             ~s|<meta charset="utf-8">caf�|
  end

  defp malformed_meta, do: ~s|<meta charset="| <> <<255>> <> ~s|">|
end
