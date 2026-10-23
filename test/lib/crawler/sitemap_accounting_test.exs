defmodule Crawler.SitemapAccountingTest do
  use ExUnit.Case, async: false

  import Crawler.TestHelpers, only: [unique_scope: 1]

  alias Crawler.Fetcher.Requester
  alias Crawler.HTTP
  alias Crawler.Options
  alias Crawler.Sitemap
  alias Crawler.Store
  alias Crawler.Store.Execution

  setup do
    scope = unique_scope("sitemap-accounting")
    on_exit(fn -> Store.drop_scope(scope) end)

    opts =
      Options.assign_defaults(%{
        scope: scope,
        url: "https://example.test/map.xml",
        site: "https://example.test/map.xml",
        sitemap_fetch: true,
        respect_robots: false,
        retries: 0
      })

    {:ok, opts: opts}
  end

  test "malformed controls consume entity bytes before parsing fails", %{opts: opts} do
    body = String.duplicate(<<233>>, 20)

    execute_owned(%{opts | max_control_bytes: byte_size(body)}, fn owned ->
      assert execute(owned, response(body)) == {:error, :invalid_encoding}
      assert execute(owned, response("<urlset/>")) == {:error, {:limit, :max_control_bytes}}
    end)
  end

  test "limited controls consume bytes before the analysis limit", %{opts: opts} do
    body = "<urlset/>"

    execute_owned(%{opts | max_control_bytes: byte_size(body)}, fn owned ->
      assert execute(%{owned | max_analysis_bytes: 4_095}, response(body)) ==
               {:error, {:limit, :max_analysis_bytes}}

      assert execute(owned, response(body)) == {:error, {:limit, :max_control_bytes}}
    end)
  end

  test "aggregate byte rejection takes precedence over malformed parsing", %{opts: opts} do
    execute_owned(%{opts | max_control_bytes: 1}, fn owned ->
      assert execute(owned, response(<<233, 233>>)) ==
               {:error, {:limit, :max_control_bytes}}
    end)
  end

  test "UTF16 is charged by entity size and HTTP plus Sitemap charge once", %{opts: opts} do
    body = <<255, 254>> <> :unicode.characters_to_binary("<urlset/>", :utf8, {:utf16, :little})
    assert byte_size(body) == 20

    execute_owned(%{opts | max_control_bytes: byte_size(body)}, fn owned ->
      assert execute(owned, response(body)) == :ok
      assert execute(owned, response("<urlset/>")) == {:error, {:limit, :max_control_bytes}}
    end)
  end

  test "gzip file expansion upgrades the current entity receipt", %{opts: opts} do
    body = "<urlset>" <> String.duplicate(" ", 1_000) <> "</urlset>"
    compressed = :zlib.gzip(body)
    assert byte_size(compressed) < byte_size(body)

    execute_owned(%{opts | max_control_bytes: byte_size(body)}, fn owned ->
      assert execute(owned, response(compressed)) == :ok
      assert execute(owned, response("<urlset/>")) == {:error, {:limit, :max_control_bytes}}
    end)
  end

  test "HTTP gzip decoding and Sitemap do not double charge the entity", %{opts: opts} do
    body = "<urlset/>"
    compressed = :zlib.gzip(body)

    response =
      Req.Response.new(status: 200, body: compressed, headers: [{"content-encoding", "gzip"}])

    execute_owned(%{opts | max_control_bytes: byte_size(body)}, fn owned ->
      assert execute(owned, response) == :ok
      assert execute(owned, response(body)) == {:error, {:limit, :max_control_bytes}}
    end)
  end

  test "body-limit failures consume the conservative per-attempt charge", %{opts: opts} do
    execute_owned(%{opts | max_body: 128, max_control_bytes: 128}, fn owned ->
      assert execute(owned, response(String.duplicate("x", 129))) ==
               {:error, {:limit, :max_body}}

      assert execute(owned, response("<urlset/>")) == {:error, {:limit, :max_control_bytes}}
    end)
  end

  test "transport and deadline failures consume central conservative charges", %{opts: opts} do
    for error <- [
          %Req.TransportError{reason: :closed},
          %HTTP.DeadlineExceeded{kind: :attempt, reason: {:deadline, :attempt}}
        ] do
      execute_owned(%{opts | max_body: 128, max_control_bytes: 128}, fn owned ->
        assert {:error, _reason} = execute(owned, error)
        assert execute(owned, response("<urlset/>")) == {:error, {:limit, :max_control_bytes}}
      end)

      Store.drop_scope(opts.scope)
    end
  end

  test "ordinary XML ingestion uses neither control slots nor bytes", %{opts: opts} do
    opts =
      Map.merge(opts, %{
        content_type: "application/xml",
        max_control_documents: 1,
        max_control_bytes: 7
      })

    execute_owned(opts, fn owned ->
      assert Sitemap.ingest(owned, "<ordinary/>") == false
    end)

    execute_owned(opts, fn owned ->
      assert Sitemap.ingest(owned, "<feed/>") == true
    end)
  end

  test "direct feed ingestion accounts once per execution lease", %{opts: opts} do
    opts =
      Map.merge(opts, %{
        content_type: "application/xml",
        max_control_documents: 1,
        max_control_bytes: 7
      })

    execute_owned(opts, fn owned ->
      assert Sitemap.ingest(owned, "<feed/>") == true
      assert Sitemap.ingest(owned, "<feed/>") == true
    end)

    execute_owned(opts, fn owned ->
      assert Sitemap.ingest(owned, "<feed/>") == {:error, {:limit, :max_control_documents}}
    end)
  end

  defp execute_owned(opts, callback) do
    assert :ok =
             Execution.run(opts, fn owned ->
               callback.(owned)
               :ok
             end)
  end

  defp response(body), do: Req.Response.new(status: 200, body: body)

  defp execute(opts, response) do
    adapter = fn request -> {request, response} end
    opts = Map.put(opts, :req_options, adapter: adapter, retry: false)

    with :ok <- Store.account_control_document(opts),
         {:ok, prepared} <- Requester.prepare(opts) do
      Sitemap.execute(opts, prepared)
    end
  end
end
