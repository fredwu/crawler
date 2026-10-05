defmodule Crawler.RedirectStorageTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store
  alias Crawler.Store.Page

  import Crawler.RedirectHelpers

  defmodule CustomStore do
    def add_page_data(key, body, opts) do
      send(opts[:storage_owner], {:stored, key, body, opts})

      if opts[:storage_retire_url] == opts[:url], do: Store.drop_scope(opts[:scope])

      if opts[:storage_error_url] == opts[:url] do
        {:error, opts[:storage_error]}
      else
        :ok
      end
    end
  end

  setup %{site: site, url: url} do
    requested = "#{url}/storage/requested"
    landing = "#{url}/storage/landing"
    body = ~s(<p>LANDING</p><a href="#{landing}">self</a>)

    ReqTestSite.expect_once(site, "GET", "/storage/requested", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", landing)
      |> Plug.Conn.resp(302, "")
    end)

    html(site, "/storage/landing", body)

    %{requested: requested, landing: landing, body: body}
  end

  test "disabled storage keeps processed redirect identities without bodies", context do
    opts = crawl_redirect(context, store: nil)
    scope = opts[:scope]

    for url <- [context.requested, context.landing] do
      assert %Page{processed: true, body: nil, opts: nil} = Store.find({url, scope})
    end

    assert Store.ops_count(scope) == 1
  end

  test "a custom store receives both bodies without writing them to the internal store",
       context do
    opts = crawl_redirect(context, store: CustomStore, storage_owner: self())
    scope = opts[:scope]
    landing = context.landing
    body = context.body

    for url <- [context.requested, landing] do
      assert_receive {:stored, {^url, ^scope}, ^body, stored_opts}
      assert stored_opts.url == url

      if url == landing, do: assert(stored_opts.referrer_url == landing)

      assert %Page{processed: true, body: nil, opts: nil} = Store.find({url, scope})
    end

    refute_receive {:stored, _, _, _}
    assert Store.ops_count(scope) == 1
  end

  test "the internal store retains both bodies when selected", context do
    opts = crawl_redirect(context, store: Store)
    body = context.body

    for url <- [context.requested, context.landing] do
      assert %Page{processed: true, body: ^body, opts: %{url: ^url}} =
               Store.find({url, opts[:scope]})
    end
  end

  for {reason, result} <- [storage_failed: {:error, :storage_failed}, stale: {:warn, :stale}] do
    test "a landing storage #{reason} releases its alias and stops processing", context do
      scope = unique_scope("redirect-storage-error")

      assert unquote(Macro.escape(result)) ==
               fetcher(%{
                 url: context.requested,
                 scope: scope,
                 retries: 0,
                 store: CustomStore,
                 storage_owner: self(),
                 storage_error_url: context.landing,
                 storage_error: unquote(reason),
                 req_options: context.req_options
               })

      refute Store.find({context.landing, scope})
      refute Store.find_processed({context.requested, scope})
    end
  end

  test "a requested storage error stops before registering the landing alias", context do
    scope = unique_scope("redirect-storage-request-error")

    assert {:error, :storage_failed} ==
             fetcher(%{
               url: context.requested,
               scope: scope,
               retries: 0,
               store: CustomStore,
               storage_owner: self(),
               storage_error_url: context.requested,
               storage_error: :storage_failed,
               req_options: context.req_options
             })

    assert_receive {:stored, {requested, ^scope}, _, _}
    assert requested == context.requested
    refute_receive {:stored, _, _, _}
    refute Store.find({context.landing, scope})
  end

  test "scope retirement during the landing callback returns a stale result", context do
    scope = unique_scope("redirect-storage-retired")
    generation = Store.generation(scope)

    assert {:warn, :stale} ==
             fetcher(%{
               url: context.requested,
               scope: scope,
               generation: generation,
               retries: 0,
               store: CustomStore,
               storage_owner: self(),
               storage_retire_url: context.landing,
               req_options: context.req_options
             })

    refute Store.generation(scope) == generation
    refute Store.find({context.requested, scope})
    refute Store.find({context.landing, scope})
  end

  defp crawl_redirect(context, options) do
    opts =
      crawl(
        context.requested,
        Keyword.merge([workers: 1, retries: 0, req_options: context.req_options], options)
      )

    await_idle(opts)
    opts
  end
end
