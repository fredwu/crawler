defmodule Crawler.RedirectHelpers do
  @moduledoc false

  alias Crawler.Fetcher
  alias Crawler.Fetcher.Modifier
  alias Crawler.Fetcher.Retrier
  alias Crawler.Fetcher.UrlFilter
  alias Crawler.ReqTestSite
  alias Crawler.Store

  defmodule HostFilter do
    @behaviour Crawler.Fetcher.UrlFilter.Spec

    def filter(url, _opts) do
      {:ok, URI.parse(url).host == "ex.com"}
    end
  end

  def new_count, do: :counters.new(1, [:atomics])

  def bump(counter), do: :counters.add(counter, 1, 1)

  def count(counter), do: :counters.get(counter, 1)

  def crawl(url, opts) do
    opts = Keyword.merge([store: Store], opts)
    {:ok, opts} = Crawler.TestHelpers.start_crawl(url, opts)
    opts
  end

  def fetcher(opts) do
    defaults = %{
      depth: 0,
      retries: 2,
      url_filter: UrlFilter,
      modifier: Modifier,
      retrier: Retrier,
      store: Store,
      html_tag: "a"
    }

    defaults
    |> Map.merge(opts)
    |> Fetcher.fetch()
  end

  def html(site, path, body) do
    ReqTestSite.expect_once(site, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, body)
    end)
  end

  def text(site, path, body) do
    ReqTestSite.expect_once(site, "GET", path, fn conn ->
      Plug.Conn.resp(conn, 200, body)
    end)
  end

  def redirect(request, location) do
    {request, Req.Response.new(status: 302, headers: [{"location", location}], body: "")}
  end

  def html_response(request, body) do
    {request, Req.Response.new(status: 200, headers: [{"content-type", "text/html"}], body: body)}
  end

  def text_response(request, body) do
    {request,
     Req.Response.new(status: 200, headers: [{"content-type", "text/plain"}], body: body)}
  end
end
