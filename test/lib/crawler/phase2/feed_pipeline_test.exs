defmodule Crawler.Phase2.FeedPipelineTest do
  use ExUnit.Case, async: false

  alias Crawler.Store
  alias Crawler.Store.Page

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
    :ok
  end

  test "UTF16 feeds and XML keep decode, lexical facts and control output on one ledger" do
    for {type, element, control?} <- [
          {"application/rss+xml", "rss", true},
          {"application/atom+xml", "feed", true},
          {"application/rdf+xml", "rdf", true},
          {"application/xml", "ordinary", false},
          {"text/xml", "ordinary", false}
        ] do
      scope = make_ref()
      on_exit(fn -> Store.dispose_scope(scope) end)
      source = "<?xml version=\"1.0\"?><#{element}><title>界</title></#{element}>"
      wire = :unicode.characters_to_binary(source, :utf8, {:utf16, :little})
      name = {__MODULE__, make_ref()}

      Req.Test.stub(name, fn conn ->
        conn |> Plug.Conn.put_resp_header("content-type", type) |> Plug.Conn.send_resp(200, wire)
      end)

      assert %Page{} =
               page =
               Crawler.crawl_now(%{
                 scope: scope,
                 url: "https://feed-pipeline.test/document",
                 respect_robots: false,
                 store: Store,
                 req_options: [plug: {Req.Test, name}]
               })

      assert String.valid?(page.body)
      assert page.body =~ "界"
      assert page.analysis.mode == :xml
      assert page.analysis.stats.scans == %{xml: 1}
      assert page.interpretation.collection.control_document == control?
      assert page.opts[:count_page] == false == control?
      assert page.interpretation.collection.budget.retained > page.analysis.budget.retained
      assert page.interpretation.collection.budget.scratch == 0
      assert page.interpretation.collection.budget.peak <= page.opts.max_analysis_bytes
      assert length(page.credit.retained) == 3
      assert length(Enum.uniq(page.credit.retained)) == 3

      state = :sys.get_state(Store)
      funded = Enum.sum(for ref <- page.credit.retained, do: state.resources.receipts[ref].actual)
      assert funded >= page.interpretation.collection.budget.retained - page.credit.unavailable
      assert state.scopes[scope].control_bytes == if(control?, do: byte_size(wire), else: 0)
      assert Store.ops_count(scope) == if(control?, do: 0, else: 1)
      assert :ok = Store.release_page(page)
    end
  end

  test "a feed releases its page reservation so its child runs with one page slot" do
    scope = make_ref()
    parent = self()
    on_exit(fn -> Store.dispose_scope(scope) end)
    name = {__MODULE__, make_ref()}

    feed =
      "<rss><channel><item><link>https://feed-pipeline.test/child</link></item></channel></rss>"

    Req.Test.stub(name, fn conn ->
      if conn.request_path == "/feed" do
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/rss+xml")
        |> Plug.Conn.send_resp(200, feed)
      else
        send(parent, :feed_child_requested)

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.send_resp(200, "child")
      end
    end)

    assert {:ok, opts} =
             Crawler.crawl("https://feed-pipeline.test/feed",
               scope: scope,
               store: Store,
               workers: 1,
               max_pages: 1,
               respect_robots: false,
               req_options: [plug: {Req.Test, name}]
             )

    on_exit(fn -> Crawler.stop(opts) end)
    assert_receive :feed_child_requested, 1_000

    await(fn ->
      assert Store.pending_count(scope) == 0
      assert Store.ops_count(scope) == 1

      assert %{status: :succeeded, reason: :control_document} =
               Store.target_outcome(opts.target_handle)
    end)
  end

  test "public binary ingestion uses a bounded execution and leaves no live executor" do
    scope = make_ref()
    on_exit(fn -> Store.dispose_scope(scope) end)

    opts = %{
      scope: scope,
      url: "https://feed-pipeline.test/feed",
      content_type: "application/rss+xml"
    }

    assert Crawler.Sitemap.ingest(opts, "<rss/>") == true
    state = :sys.get_state(Store)
    assert state.scopes[scope].control_documents == 1

    assert Enum.all?(state.executions, fn {_lease, execution} -> execution.opts.scope != scope end)

    assert Crawler.Sitemap.ingest(Map.put(opts, :max_body, 0), "<rss/>") ==
             {:error, {:limit, :max_body}}
  end

  defp await(check, attempts \\ 200)

  defp await(check, attempts) when attempts > 0 do
    try do
      check.()
    rescue
      ExUnit.AssertionError ->
        receive do
        after
          5 -> :ok
        end

        await(check, attempts - 1)
    end
  end

  defp await(check, 0), do: check.()
end
