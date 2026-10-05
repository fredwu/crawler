defmodule Crawler.LoggingPrivacyTest do
  use ExUnit.Case, async: false

  import Crawler.TestHelpers, only: [unique_scope: 1, tmp: 1]

  alias Crawler.Options
  alias Crawler.Store
  alias Crawler.Store.Page

  @basic "basic-user:basic-password"
  @bearer "private-bearer-token"
  @authorization "Bearer private-header-token"
  @userinfo "private-url-user:private-url-password"
  @cookie "session=private-cookie"
  @private "private-modifier-option"
  @secrets [
    @basic,
    "basic-user",
    "basic-password",
    Base.encode64(@basic),
    @bearer,
    @authorization,
    "private-header-token",
    @userinfo,
    "private-url-user",
    "private-url-password",
    "private-target-user",
    "private-target-password",
    @cookie,
    @private
  ]

  defmodule CredentialsModifier do
    @behaviour Crawler.Fetcher.Modifier.Spec

    def headers(opts) do
      headers = [{"cookie", opts[:private_cookie]}]

      if opts[:authorization],
        do: [{"authorization", opts[:authorization]} | headers],
        else: headers
    end

    def opts(_opts), do: []
  end

  defmodule RejectFilter do
    @behaviour Crawler.Fetcher.UrlFilter.Spec

    def filter(url, opts) do
      send(opts[:observer], {:filtered, url})
      {:ok, false}
    end
  end

  defmodule SensitiveParser do
    def parse(%Page{body: "allowed"} = page), do: {:ok, page}
  end

  defmodule RejectLandingFilter do
    @behaviour Crawler.Fetcher.UrlFilter.Spec

    def filter(url, _opts), do: {:ok, URI.parse(url).path != "/logging/private"}
  end

  for credential <- [:basic, :bearer, :authorization, :userinfo] do
    test "normal #{credential} requests keep credentials out of captured logs" do
      opts = crawl_opts(unquote(credential))

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert %Page{url: url} = Crawler.crawl_now(opts)
          assert url == opts.url
        end)

      assert_receive {:requested, url, authorization, cookie}
      assert url == opts.url
      assert cookie == [@cookie]
      assert authorization == expected_authorization(unquote(credential))
      assert log =~ "Running worker"
      assert log =~ "Fetched http://example.com/logging/"
      assert_private(log)
    end

    test "a rejected #{credential} request keeps useful policy diagnostics without credentials" do
      opts = Map.put(crawl_opts(unquote(credential)), :url_filter, RejectFilter)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert {:warn, message} = Crawler.crawl_now(opts)
          assert message =~ "perform_url_filtering"
          assert message =~ "depth: 0"
          assert_private(message)
        end)

      assert_receive {:filtered, url}
      assert url == opts.url
      refute_received {:requested, _, _, _}
      assert log =~ "perform_url_filtering"
      assert log =~ "max_depths: 3"
      assert_private(log)
    end
  end

  for status <- [404, 500] do
    test "a #{status} fetch response redacts URL userinfo in its result and logs" do
      opts = crawl_opts(:userinfo, unquote(status))

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert {_, message} = Crawler.crawl_now(opts)
          assert message =~ "status code: #{unquote(status)}"
          assert_private(message)
        end)

      assert log =~ "Failed to fetch http://example.com/logging/userinfo"
      assert_private(log)
    end
  end

  test "a callback function clause failure logs its location without its credential arguments" do
    opts = Map.put(crawl_opts(:bearer), :parser, SensitiveParser)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert {:error, {:error, :function_clause}} = Crawler.crawl_now(opts)
      end)

    assert log =~ "FunctionClauseError"
    assert log =~ "SensitiveParser.parse/1"
    assert_private(log)
  end

  test "rejected redirects redact credentials in both requested and landing addresses" do
    next = "http://private-target-user:private-target-password@example.com/logging/private"

    opts =
      :userinfo
      |> crawl_opts()
      |> Map.put(:url_filter, RejectLandingFilter)
      |> put_adapter(fn request ->
        {request, Req.Response.new(status: 302, headers: [{"location", next}], body: "")}
      end)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert {:warn, message} = Crawler.crawl_now(opts)
        assert message =~ "Redirect rejected for http://example.com/logging/userinfo"
        assert message =~ "to http://example.com/logging/private"
        assert_private(message)
      end)

    assert log =~ "Redirect rejected"
    assert_private(log)
  end

  test "a request exception does not expose its credential-bearing message" do
    opts =
      :bearer
      |> crawl_opts()
      |> put_adapter(fn request -> {request, %RuntimeError{message: @bearer}} end)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert {:error, message} = Crawler.crawl_now(opts)
        assert message =~ "reason: RuntimeError"
        assert_private(message)
      end)

    assert_private(log)
  end

  test "transport failures keep useful atom reasons without URL userinfo" do
    opts =
      :userinfo
      |> crawl_opts()
      |> put_adapter(fn request -> {request, %Req.TransportError{reason: :timeout}} end)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert {:error, message} = Crawler.crawl_now(opts)
        assert message =~ "reason: :timeout"
        assert_private(message)
      end)

    assert_private(log)
  end

  test "a publication callback preserves its original error type without its secret message" do
    root = tmp(unique_scope("private-publication"))
    on_exit(fn -> File.rm_rf(root) end)

    opts = crawl_opts(:bearer)

    opts =
      Map.merge(opts, %{
        generation: Store.generation(opts.scope),
        save_to: root,
        retries: 3,
        before_publish: fn -> raise @bearer end
      })

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert {:error, {:error, %RuntimeError{message: @bearer}}} = Crawler.crawl_now(opts)
      end)

    assert log =~ "RuntimeError"
    assert log =~ "Crawler.Snapper.publish/3"
    refute log =~ "FunctionClauseError"
    assert_private(log)
  end

  test "a malformed credential-bearing root URL is safe before HTTP validation" do
    opts = %{crawl_opts(:userinfo) | url: "http://#{@userinfo}@/logging/private"}

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert {:error, message} = Crawler.crawl_now(opts)
        assert message =~ "Failed to fetch <invalid URL>"
        assert message =~ "Crawler.HTTP.InvalidURL"
        assert_private(message)
      end)

    refute_received {:requested, _, _, _}
    assert log =~ "Running worker"
    assert log =~ "<invalid URL>"
    assert_private(log)
  end

  test "a policy-rejected malformed root URL returns a warning without its credentials" do
    invalid = "http://#{@userinfo}@/logging/private"
    opts = Map.merge(crawl_opts(:userinfo), %{url: invalid, url_filter: RejectFilter})

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert {:warn, message} = Crawler.crawl_now(opts)
        assert message =~ "perform_url_filtering"
        assert message =~ "<invalid URL>"
        assert message =~ "depth: 0"
        assert_private(message)
      end)

    assert_receive {:filtered, ^invalid}
    refute_received {:requested, _, _, _}
    assert_private(log)
  end

  test "a malformed credential-bearing redirect is warned about without making its request" do
    invalid = "http://#{@userinfo}@/logging/private"
    requests = :counters.new(1, [:atomics])

    opts =
      :bearer
      |> crawl_opts()
      |> put_adapter(fn request ->
        :counters.add(requests, 1, 1)
        {request, Req.Response.new(status: 302, headers: [{"location", invalid}], body: "")}
      end)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert {:warn, message} = Crawler.crawl_now(opts)

        assert message =~
                 "Redirect rejected for http://example.com/logging/bearer to <invalid URL>"

        assert_private(message)
      end)

    assert :counters.get(requests, 1) == 1
    assert log =~ "Redirect rejected"
    assert_private(log)
  end

  test "an allowed credential-bearing redirect reaches its landing without raw redirect logs" do
    next = "http://private-target-user:private-target-password@example.com/logging/private"
    observer = self()

    opts =
      :userinfo
      |> crawl_opts()
      |> put_adapter(fn request ->
        send(observer, {:allowed_hop, URI.to_string(request.url)})

        response =
          case request.url.path do
            "/logging/userinfo" ->
              Req.Response.new(status: 302, headers: [{"location", next}], body: "")

            "/logging/private" ->
              Req.Response.new(status: 200, body: "REDIRECT BODY")
          end

        {request, response}
      end)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert %Page{body: "REDIRECT BODY", opts: page_opts} = Crawler.crawl_now(opts)
        assert page_opts.referrer_url == next
        assert Store.find_processed({next, opts.scope})
      end)

    assert_receive {:allowed_hop, requested}
    assert requested == opts.url
    assert_receive {:allowed_hop, ^next}
    refute_received {:allowed_hop, _}
    assert log =~ "Fetched http://example.com/logging/userinfo"
    refute log =~ "redirecting to"
    assert_private(log)
  end

  defp crawl_opts(credential, status \\ 200) do
    scope = unique_scope("logging-#{credential}")
    on_exit(fn -> Store.drop_scope(scope) end)
    observer = self()

    adapter = fn request ->
      send(observer, {
        :requested,
        URI.to_string(request.url),
        Req.Request.get_header(request, "authorization"),
        Req.Request.get_header(request, "cookie")
      })

      {request, Req.Response.new(status: status, body: "BODY")}
    end

    opts =
      Options.assign_defaults(%{
        scope: scope,
        url: "http://example.com/logging/#{credential}",
        observer: observer,
        modifier: CredentialsModifier,
        private_cookie: @cookie,
        private_modifier_option: @private,
        retries: 0,
        req_options: [adapter: adapter, retry: false]
      })

    case credential do
      :basic -> put_in(opts.req_options[:auth], {:basic, @basic})
      :bearer -> put_in(opts.req_options[:auth], {:bearer, @bearer})
      :authorization -> Map.put(opts, :authorization, @authorization)
      :userinfo -> %{opts | url: "http://#{@userinfo}@example.com/logging/userinfo"}
    end
  end

  defp expected_authorization(:basic), do: ["Basic " <> Base.encode64(@basic)]
  defp expected_authorization(:bearer), do: ["Bearer " <> @bearer]
  defp expected_authorization(:authorization), do: [@authorization]
  defp expected_authorization(:userinfo), do: []

  defp put_adapter(opts, adapter), do: put_in(opts.req_options[:adapter], adapter)

  defp assert_private(text) do
    Enum.each(@secrets, fn secret -> refute text =~ secret end)
    refute text =~ "req_options"
    refute text =~ "private_modifier_option"
  end
end
