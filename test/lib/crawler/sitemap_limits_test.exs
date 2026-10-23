defmodule Crawler.SitemapLimitsTest do
  use ExUnit.Case, async: true

  alias Crawler.Deadline
  alias Crawler.Limits
  alias Crawler.Sitemap

  test "expired control execution stops before using the prepared request" do
    for kind <- [:attempt, :run] do
      opts = opts(%{crawler_deadline: Deadline.after_ms(0, kind)})
      assert Sitemap.execute(opts, nil) == {:error, {:deadline, kind}}
    end
  end

  test "expired feed ingestion stops before parsing or accounting" do
    opts = opts(%{deadline: Deadline.after_ms(0, :run)})
    assert Sitemap.ingest(opts, "<feed/>") == {:error, {:deadline, :run}}
  end

  test "ordinary XML and plain text are not ingested as catalogues" do
    assert Sitemap.ingest(opts(), "<document><loc>/page</loc></document>") == false
    assert Sitemap.ingest(opts(), "https://example.test/page") == false
    assert Sitemap.ingest(%{}, "<feed/>") == false
  end

  test "feed parsing receives the analysis output limit" do
    assert Sitemap.ingest(opts(%{max_analysis_bytes: 4_095}), "<feed/>") ==
             {:error, {:limit, :analysis_bytes}}
  end

  test "gzip expansion uses the decoded body limit" do
    body = "<feed>" <> String.duplicate(" ", 10_000) <> "</feed>"
    compressed = :zlib.gzip(body)
    assert byte_size(compressed) < 128

    assert Sitemap.ingest(opts(%{max_body: 128}), compressed) ==
             {:error, {:limit, :max_body}}
  end

  test "invalid and truncated gzip members fail without admitting entries" do
    body = :zlib.gzip("<feed/>")
    truncated = binary_part(body, 0, byte_size(body) - 4)

    for invalid <- [<<31, 139, 0, 0>>, truncated] do
      assert Sitemap.ingest(opts(), invalid) == {:error, :invalid_gzip}
    end
  end

  test "locations uses bounded parsing and preserves unresolved addresses" do
    assert Sitemap.locations("<urlset><url><loc>relative</loc></url></urlset>") ==
             {["relative"], []}

    deep = String.duplicate("<n>", 257) <> "</n>"
    assert Sitemap.locations(deep) == {[], []}
  end

  defp opts(overrides \\ %{}) do
    Limits.defaults()
    |> Map.merge(%{content_type: "application/xml", url: "https://example.test/feed.xml"})
    |> Map.merge(overrides)
  end
end
