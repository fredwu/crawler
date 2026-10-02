defmodule Crawler.OfflineLinkCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Crawler.Snapper.LinkReplacer

  using do
    quote do
      import Crawler.OfflineLinkCase

      alias Crawler.Linker

      @page "http://example.com/blog/post"
    end
  end

  def rewrite(body, url, content_type \\ "text/html", html_tag \\ "a") do
    assert {:ok, rewritten} =
             LinkReplacer.replace_links(body, %{
               url: url,
               referrer_url: url,
               content_type: content_type,
               html_tag: html_tag,
               assets: ["images", "css", "js"],
               depth: 1,
               max_depths: 3
             })

    rewritten
  end

  def assert_points(body, from_url, target_url, fragment \\ "") do
    Crawler.SnapshotHelpers.assert_points(body, from_url, target_url, ".", fragment)
  end

  def occurrences(body, text) do
    body |> String.split(text) |> length() |> Kernel.-(1)
  end
end
