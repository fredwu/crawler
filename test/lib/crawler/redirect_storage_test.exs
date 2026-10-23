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

  defmodule FrozenRequestParser do
    def parse(%Page{} = page) do
      send(page.opts.frozen_request_owner, {
        :frozen_request,
        page.target_handle,
        URI.to_string(page.opts.prepared_request.request.url),
        page.opts.representation_id
      })

      Crawler.Parser.parse(page)
    end

    def parse(other), do: Crawler.Parser.parse(other)
  end

  defmodule FailedSourceParser do
    def parse(%Page{} = page) do
      result = FrozenRequestParser.parse(page)

      if page.url == page.opts[:fail_after_completion_url] do
        :ok =
          Store.complete_page(
            {page.url, page.opts.scope},
            page.opts.generation,
            page.opts.queue,
            page.opts[:alias_url],
            false
          )

        send(page.opts.frozen_request_owner, {:failed_source_target, page.target_handle})
        {:error, :source_failed_after_completion}
      else
        result
      end
    end

    def parse(other), do: FrozenRequestParser.parse(other)
  end

  setup %{site: site, url: url} = context do
    requested = "#{url}/storage/requested"
    landing = "#{url}/storage/landing"
    body = ~s(<p>LANDING</p><a href="#{landing}">self</a>)

    ReqTestSite.expect_once(site, "GET", "/storage/requested", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", landing)
      |> Plug.Conn.resp(302, "")
    end)

    expected = context[:landing_requests] || 1
    requests = :counters.new(1, [:atomics])

    response = fn conn ->
      :counters.add(requests, 1, 1)
      assert :counters.get(requests, 1) <= expected

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, body)
    end

    if expected == 1,
      do: ReqTestSite.expect_once(site, "GET", "/storage/landing", response),
      else: ReqTestSite.expect(site, "GET", "/storage/landing", response)

    on_exit(fn -> assert :counters.get(requests, 1) == expected end)
    %{requested: requested, landing: landing, body: body}
  end

  @tag landing_requests: 2
  test "disabled storage keeps processed redirect identities without bodies", context do
    opts = crawl_redirect(context, store: nil)
    scope = opts[:scope]

    for url <- [context.requested, context.landing] do
      assert %Page{
               url: ^url,
               processed: true,
               body: nil,
               opts: nil,
               analysis: nil,
               interpretation: nil,
               source_revision: nil,
               credit: nil,
               target_handle: target,
               fetch_tag: tag,
               picture_type: nil
             } = Store.find({url, scope})

      assert is_reference(target)
      assert tag == if(url == context.requested, do: "a")
    end

    assert Store.ops_count(scope) == 1
  end

  @tag landing_requests: 2
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

      assert %Page{
               url: ^url,
               processed: true,
               body: nil,
               opts: nil,
               analysis: nil,
               interpretation: nil,
               source_revision: nil,
               credit: nil,
               target_handle: target,
               fetch_tag: tag,
               picture_type: nil
             } = Store.find({url, scope})

      assert is_reference(target)
      assert tag == if(url == context.requested, do: "a")
    end

    assert_receive {:stored, {^landing, ^scope}, ^body, direct_opts}
    assert direct_opts.url == landing
    assert direct_opts.referrer_url == landing
    refute_receive {:stored, _, _, _}
    assert Store.ops_count(scope) == 1
  end

  @tag landing_requests: 2
  test "the internal store retains both bodies when selected", context do
    opts = crawl_redirect(context, store: Store)
    body = context.body

    for url <- [context.requested, context.landing] do
      assert %Page{processed: true, body: ^body, opts: %{url: ^url}} =
               Store.find({url, opts[:scope]})
    end
  end

  @tag landing_requests: 2
  test "a source failure after page completion does not count a later landing success twice",
       context do
    opts =
      crawl_redirect(context,
        parser: FailedSourceParser,
        fail_after_completion_url: context.requested,
        store: Store
      )

    assert_receive {:failed_source_target, target}

    assert %{status: :failed, reason: :source_failed_after_completion} =
             Store.target_outcome(target)

    assert Store.find_processed({context.landing, opts.scope})
    assert Store.ops_count(opts.scope) == 1
  end

  for {reason, result} <- [storage_failed: {:error, :storage_failed}, stale: {:warn, :stale}] do
    test "a landing storage #{reason} releases its alias and stops processing", context do
      scope = unique_scope("redirect-storage-error")

      assert unquote(Macro.escape(result)) ==
               fetcher(%{
                 url: context.requested,
                 max_body: 1_048_576,
                 max_analysis_bytes: 16_000_000,
                 max_css_work: 5_000,
                 max_css_pictures: 1_000,
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
               max_body: 1_048_576,
               max_analysis_bytes: 16_000_000,
               max_css_work: 5_000,
               max_css_pictures: 1_000,
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
               max_body: 1_048_576,
               max_analysis_bytes: 16_000_000,
               max_css_work: 5_000,
               max_css_pictures: 1_000,
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
        Keyword.merge(
          [
            workers: 1,
            parser: FrozenRequestParser,
            frozen_request_owner: self(),
            max_body: 1_048_576,
            max_analysis_bytes: 16_000_000,
            max_css_work: 5_000,
            max_css_pictures: 1_000,
            retries: 0,
            req_options: context.req_options
          ],
          options
        )
      )

    await_idle(opts)

    frozen =
      for _ <- 1..3 do
        assert_receive {:frozen_request, target, initial_url, representation}
        {target, initial_url, representation}
      end

    assert length(Enum.uniq_by(frozen, &elem(&1, 0))) == 3

    assert Enum.sort(Enum.uniq(Enum.map(frozen, &elem(&1, 1)))) ==
             Enum.sort([context.requested, context.landing])

    assert length(Enum.uniq_by(frozen, &elem(&1, 2))) == 2
    refute_receive {:frozen_request, _, _, _}
    opts
  end
end
