defmodule Crawler.Parser.HTMLChildAssociationTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.HtmlParser

  test "a template predecessor cannot supply live children with identical attributes" do
    source =
      ~s|<template><a href="next">In<b>Template</b></a></template>| <>
        ~s|<a href="next">Out<b>Live</b></a><a href="next">Later</a>|

    assert HtmlParser.parse(source, %{}) == [
             {"a", [{"href", "next"}], ["Out", {"b", [], ["Live"]}]},
             {"a", [{"href", "next"}], ["Later"]}
           ]
  end

  test "a foreign predecessor cannot supply an identical live HTML anchor's children" do
    source =
      ~s|<math><a href="next">Math<b>Foreign</b></a></math>| <>
        ~s|<a href="next">Out<b>Live</b></a>|

    assert HtmlParser.parse(source, %{}) == [
             {"a", [{"href", "next"}], ["Out", {"b", [], ["Live"]}]}
           ]
  end

  test "source identity does not collide with existing attributes or leak into nested children" do
    script = ~s|<!--<script></script><a href="ignored">Hidden</a>-->|

    source =
      ~s|<template><a DATA-CRAWLER-SOURCE="user" href=next/>In</a></template>| <>
        ~s|<a DATA-CRAWLER-SOURCE="user" data-crawler-source="ignored" href=next/ href="ignored">Out| <>
        ~s|<b data-crawler-source-="nested">Bold</b>| <>
        ~s|<script data-crawler-source--="script">#{script}</script></a>|

    assert HtmlParser.parse(source, %{assets: ["js"]}) == [
             {"a", [{"data-crawler-source", "user"}, {"href", "next/"}],
              [
                "Out",
                {"b", [{"data-crawler-source-", "nested"}], ["Bold"]},
                {"script", [{"data-crawler-source--", "script"}], [script]}
              ]},
             {"script", [{"data-crawler-source--", "script"}], [script]}
           ]
  end

  test "nested eligible elements and an EOF-complete tag keep their own child trees" do
    source =
      ~s|<template><div style="background:url(asset.png)"><a href="next">In</a></div></template>| <>
        ~s|<div style="background:url(asset.png)"><a href="next">Out</a></div>| <>
        ~s|<svg><a href="next"/></svg><a href="next">EOF|

    assert HtmlParser.parse(source, %{assets: ["css"]}) == [
             {"div", [{"style", "background:url(asset.png)"}],
              [{"a", [{"href", "next"}], ["Out"]}]},
             {"a", [{"href", "next"}], ["Out"]},
             {"a", [{"href", "next"}], []},
             {"a", [{"href", "next"}], ["EOF"]}
           ]
  end
end
