defmodule Crawler.Fetcher.PreparedRequestTest do
  use ExUnit.Case, async: false

  alias Crawler.Fetcher.Requester
  alias Crawler.Fetcher.Requester.PreparedRequest.ReuseDisposition
  alias Crawler.Store

  defmodule CountingModifier do
    def opts(opts) do
      send(opts[:owner], :modifier_options)

      [
        auth: fn ->
          send(opts[:owner], :auth)
          {:bearer, "frozen"}
        end,
        params: [source: "modifier"]
      ]
    end

    def headers(opts) do
      send(opts[:owner], :modifier_headers)
      [{"x-precedence", "modifier"}]
    end
  end

  defmodule HeaderModifier do
    def headers(_opts), do: [{"x-precedence", "callback"}, {"x-callback", "retained"}]

    def opts(_opts),
      do: [headers: [{"x-precedence", "modifier-option"}], auth: {:bearer, "modifier"}]
  end

  defmodule AuthorityModifier do
    def opts(opts) do
      send(opts[:owner], {:modifier_options, opts[:url]})
      [auth: {:bearer, "frozen"}]
    end

    def headers(opts) do
      send(opts[:owner], {:modifier_headers, opts[:url]})
      [{"cookie", "caller=one"}, {"x-frozen", "one"}]
    end
  end

  defmodule CookiePolicyModifier do
    def headers(_opts), do: []
    def opts(_opts), do: [plugins: [&register/1], max_cookie_updates: 99]

    def register(request) do
      request
      |> Req.Request.register_options([:max_cookie_updates])
      |> Req.Request.put_private(:crawler_cookie_limits, %{max_cookie_updates: 99})
    end
  end

  setup do
    original = Application.fetch_env(:req, :default_options)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:req, :default_options, value)
        :error -> Application.delete_env(:req, :default_options)
      end
    end)

    :ok
  end

  test "global bearer and authorization headers cannot reach a foreign first hop or redirect" do
    owner = self()

    adapter = fn request ->
      send(owner, {:hop, URI.to_string(request.url), request.headers})

      response =
        if request.url.path == "/first",
          do: Req.Response.new(status: 302, headers: [{"location", "/last"}]),
          else: Req.Response.new(status: 200, body: "OK")

      {request, response}
    end

    for defaults <- [
          [auth: {:bearer, "global-secret"}],
          [headers: [{"authorization", "global-secret"}, {"x-secret", "global-secret"}]]
        ] do
      Req.default_options(defaults)

      assert {:ok, _} =
               Requester.make(%{
                 url: "https://foreign.test/first",
                 site: "https://seed.test/",
                 reference_tag: "script",
                 req_options: [adapter: adapter]
               })

      assert_received {:hop, "https://foreign.test/first", first}
      assert_received {:hop, "https://foreign.test/last", last}

      for headers <- [first, last] do
        refute Map.has_key?(headers, "authorization")
        refute Map.has_key?(headers, "x-secret")
      end
    end

    Req.default_options(auth: {:bearer, "global-secret"})

    redirect_adapter = fn request ->
      send(owner, {:authorization, request.url.host, request.headers["authorization"]})

      response =
        if request.url.host == "seed.test",
          do: Req.Response.new(status: 302, headers: [{"location", "https://foreign.test/last"}]),
          else: Req.Response.new(status: 200, body: "OK")

      {request, response}
    end

    assert {:ok, _} =
             Requester.make(%{
               url: "https://seed.test/first",
               site: "https://seed.test/",
               reference_tag: "script",
               req_options: [adapter: redirect_adapter]
             })

    assert_received {:authorization, "seed.test", ["Bearer global-secret"]}
    assert_received {:authorization, "foreign.test", nil}
  end

  test "preparation runs modifiers and auth once and transport sends the frozen headers and URL" do
    owner = self()

    adapter = fn request ->
      send(owner, {:wire, request.url, request.headers})
      {request, Req.Response.new(status: 200, body: "OK")}
    end

    opts = %{
      url: "https://seed.test/a",
      owner: owner,
      modifier: CountingModifier,
      req_options: [adapter: adapter]
    }

    assert {:ok, prepared} = Requester.prepare(opts)
    assert_receive :modifier_options
    assert_receive :modifier_headers
    assert_receive :auth
    refute_received {:wire, _, _}
    assert prepared.request.request_steps == []
    assert prepared.request.current_request_steps == []
    Req.default_options(auth: {:bearer, "changed"}, headers: [{"x-precedence", "changed"}])
    assert {:ok, _} = Requester.send(prepared)
    assert_receive {:wire, url, headers}
    assert url == prepared.request.url
    assert headers == prepared.request.headers
    assert headers["authorization"] == ["Bearer frozen"]
    assert URI.to_string(url) == "https://seed.test/a?source=modifier"
    refute_received :modifier_options
    refute_received :modifier_headers
    refute_received :auth
  end

  test "header and auth precedence includes defaults, modifier options and explicit request options" do
    Req.default_options(
      auth: {:bearer, "default"},
      headers: [{"x-precedence", "default"}, {"x-default", "retained"}]
    )

    assert {:ok, prepared} =
             Requester.prepare(%{
               url: "https://seed.test/",
               modifier: HeaderModifier,
               req_options: [headers: [{"X-Precedence", "explicit"}], auth: {:bearer, "explicit"}]
             })

    assert prepared.request.headers["x-precedence"] == ["explicit"]
    assert prepared.request.headers["x-default"] == ["retained"]
    assert prepared.request.headers["x-callback"] == ["retained"]
    assert prepared.request.headers["authorization"] == ["Bearer explicit"]
  end

  test "equivalence uses actual ordered request headers, credentials and transport options, excluding interpretation goals" do
    opts = %{
      url: "https://seed.test/a",
      req_options: [auth: {:bearer, "secret-a"}, headers: [{"x-multi", ["one", "two"]}]]
    }

    assert {:ok, first} = Requester.prepare(Map.put(opts, :javascript_goal, :module))
    assert {:ok, second} = Requester.prepare(Map.put(opts, :javascript_goal, :classic))
    assert first.equivalence == second.equivalence

    for variant <- [
          %{
            opts
            | req_options: [auth: {:bearer, "secret-b"}, headers: [{"x-multi", ["one", "two"]}]]
          },
          %{
            opts
            | req_options: [auth: {:bearer, "secret-a"}, headers: [{"x-multi", ["two", "one"]}]]
          },
          %{opts | req_options: opts.req_options ++ [connect_options: [timeout: 123]]},
          Map.put(opts, :cookie_site, "https://partition.test/")
        ] do
      assert {:ok, prepared} = Requester.prepare(variant)
      refute first.equivalence == prepared.equivalence
    end

    for private <- [first, first.equivalence, first.context] do
      refute inspect(private) =~ "secret-a"
      refute inspect(private) =~ "authorization"
      refute inspect(private) =~ "seed.test"
    end
  end

  test "ordinary Req.Test requests share equivalent preparations and use the real Req plug adapter" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.resp(conn, 200, "plug body") end)
    opts = %{url: "https://seed.test/a", req_options: [plug: {Req.Test, __MODULE__}]}
    assert {:ok, first} = Requester.prepare(opts)
    assert {:ok, second} = Requester.prepare(opts)
    assert first.equivalence == second.equivalence
    assert {:ok, %Req.Response{body: "plug body"}} = Requester.send(first)
  end

  test "deferred adapters, lazy bodies and response callbacks stay private on repeated sends" do
    name = {__MODULE__, make_ref()}
    Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 200, "OK") end)
    adapter = fn request -> {request, Req.Response.new(status: 200, body: "OK")} end
    into = fn _event, result -> {:cont, result} end

    for options <- [
          [adapter: adapter],
          [plug: {Req.Test, name}, body: Stream.map(["payload"], & &1)],
          [plug: {Req.Test, name}, into: into],
          [plug: {Req.Test, name}, retry: fn _, _ -> false end],
          [plug: {Req.Test, name}, retry_delay: fn _ -> 0 end]
        ] do
      opts = %{url: "https://seed.test/", req_options: options}
      assert {:ok, first} = Requester.prepare(opts)
      assert {:ok, second} = Requester.prepare(opts)
      refute first.equivalence == second.equivalence
      frozen = first.request

      for _ <- 1..2 do
        assert {:ok, response} = Requester.send(first)
        assert response.body == "OK"

        assert %ReuseDisposition{disposition: :private, reason: :opaque_behavior} =
                 Requester.reuse_disposition(response)

        assert first.request === frozen
      end
    end
  end

  test "a built-in request step that wraps the transport is checked after preparation" do
    name = {__MODULE__, make_ref()}
    Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 200, "OK") end)
    opts = %{url: "https://seed.test/", req_options: [plug: {Req.Test, name}]}
    assert {:ok, prepared} = Requester.prepare(opts)
    refute prepared.context.opaque?
    assert {:ok, response} = Requester.send(prepared)
    assert Requester.reuse_disposition(response).disposition == :candidate
  end

  test "one canonical cookie policy survives application changes and separates redirect-visible equality" do
    keys = Map.keys(Crawler.Cookies.limits())
    originals = Map.new(keys, &{&1, Application.fetch_env(:crawler, &1)})

    try do
      Enum.each(keys, &Application.put_env(:crawler, &1, 2))
      opts = %{url: "https://seed.test/", max_cookie_bytes: 64}
      normalized = Crawler.Options.assign_defaults(opts)
      assert {:ok, prepared} = Requester.prepare(normalized)
      assert prepared.context.cookie_limits == Crawler.Limits.cookies(normalized)
      assert prepared.context.cookie_limits.max_cookie_bytes == 64
      Enum.each(keys, &Application.put_env(:crawler, &1, 99))
      assert {:ok, preserved} = Requester.prepare(normalized)
      assert preserved.context.cookie_limits == prepared.context.cookie_limits
      assert preserved.equivalence == prepared.equivalence
      assert {:ok, standalone} = Requester.prepare(opts)
      assert standalone.context.cookie_limits.max_cookie_updates == 99
      refute standalone.equivalence == prepared.equivalence
    after
      Enum.each(originals, fn
        {key, {:ok, value}} -> Application.put_env(:crawler, key, value)
        {key, :error} -> Application.delete_env(:crawler, key)
      end)
    end
  end

  test "global Req defaults and modifier options cannot inject a response cookie policy" do
    original = Application.fetch_env(:req, :default_options)
    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      Plug.Conn.send_resp(
        %{conn | resp_headers: [{"set-cookie", "a=1; Path=/"}, {"set-cookie", "b=2; Path=/"}]},
        200,
        "OK"
      )
    end)

    try do
      for source <- [:global, :modifier] do
        Req.default_options(if source == :global, do: CookiePolicyModifier.opts(%{}), else: [])
        scope = unique()
        generation = Store.generation(scope)

        opts = %{
          url: "https://seed.test/",
          scope: scope,
          generation: generation,
          max_cookie_updates: 1,
          req_options: [plug: {Req.Test, name}]
        }

        opts =
          if source == :modifier, do: Map.put(opts, :modifier, CookiePolicyModifier), else: opts

        assert {:ok, prepared} = Requester.prepare(opts)
        assert prepared.context.cookie_limits.max_cookie_updates == 1
        assert prepared.request.private.crawler_cookie_limits.max_cookie_updates == 1
        assert {:ok, _response} = Requester.send(prepared)
        assert Store.cookie_header(scope, opts.url, generation) == "a=1"
        assert :sys.get_state(Store).cookie_outcomes[scope].limits == [:max_cookie_updates]
      end
    after
      case original do
        {:ok, value} -> Application.put_env(:req, :default_options, value)
        :error -> Application.delete_env(:req, :default_options)
      end
    end
  end

  test "auth callbacks freeze their effective value and preserve ordinary Req.Test sharing" do
    session = start_supervised!({Agent, fn -> "A" end})
    owner = self()
    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      Plug.Conn.send_resp(conn, 200, Enum.join(Plug.Conn.get_req_header(conn, "authorization")))
    end)

    auth = fn ->
      send(owner, :frozen_auth_callback)
      {:bearer, Agent.get(session, & &1)}
    end

    opts = %{url: "https://seed.test/", req_options: [plug: {Req.Test, name}, auth: auth]}
    assert {:ok, first} = Requester.prepare(opts)
    assert {:ok, second} = Requester.prepare(opts)
    assert first.equivalence == second.equivalence
    assert_receive :frozen_auth_callback
    assert_receive :frozen_auth_callback
    Agent.update(session, fn _ -> "B" end)
    assert {:ok, %Req.Response{body: "Bearer A"} = response} = Requester.send(first)
    assert Requester.reuse_disposition(response).disposition == :candidate
    refute_received :frozen_auth_callback
  end

  test "all cookie limits use canonical validation before any modifier or transport" do
    for key <- Map.keys(Crawler.Cookies.limits()), value <- [0, -1, :infinity, "2"] do
      opts = %{url: "https://seed.test/", modifier: CountingModifier, owner: self()}

      assert {:error, {:request_preparation, :invalid_options}} =
               Requester.prepare(Map.put(opts, key, value))

      refute_received :modifier_options
    end
  end

  test "opaque plugin steps never share and run once through redirect and retry" do
    owner = self()

    step = fn request ->
      send(owner, :plugin_step)
      Req.Request.put_header(request, "x-plugin", "one")
    end

    plugin = fn request -> Req.Request.append_request_steps(request, opaque: step) end
    Req.default_options(plugins: [plugin])

    adapter = fn request ->
      response =
        if request.url.path == "/first",
          do: Req.Response.new(status: 302, headers: [{"location", "/last"}]),
          else: Req.Response.new(status: 200, body: "OK")

      {request, response}
    end

    opts = %{url: "https://seed.test/first", req_options: [adapter: adapter]}
    assert {:ok, first} = Requester.prepare(opts)
    assert {:ok, second} = Requester.prepare(opts)
    refute first.equivalence == second.equivalence
    assert_receive :plugin_step
    assert_receive :plugin_step
    assert {:ok, _} = Requester.send(first)
    refute_received :plugin_step
  end

  test "halted and short-circuited request plugins return tagged preparation errors without transport" do
    owner = self()

    adapter = fn request ->
      send(owner, :transport)
      {request, Req.Response.new(status: 200)}
    end

    for step <- [
          fn request -> Req.Request.halt(request, Req.Response.new(status: 200)) end,
          fn _request -> raise "private detail" end
        ] do
      Req.default_options(
        plugins: [fn request -> Req.Request.prepend_request_steps(request, short: step) end]
      )

      assert {:error, {:request_preparation, reason}} =
               Requester.prepare(%{url: "https://seed.test/", req_options: [adapter: adapter]})

      assert reason in [:short_circuited, :step_failed]
    end

    refute_received :transport
  end

  test "initial cookies freeze while redirect cookies use the current eligible jar and retain duplicate order" do
    scope = unique()
    generation = Store.generation(scope)
    url = "https://seed.test/account/first"

    Store.save_cookies(
      scope,
      url,
      ["id=root; Path=/; Secure", "id=account; Path=/account; Secure"],
      generation
    )

    owner = self()

    adapter = fn request ->
      send(owner, {:cookie, request.url.path, request.headers["cookie"]})

      response =
        if request.url.path == "/account/first",
          do:
            Req.Response.new(
              status: 302,
              headers: [
                {"location", "/account/last"},
                {"set-cookie", "next=redirect; Path=/; Secure"}
              ]
            ),
          else: Req.Response.new(status: 200, body: "OK")

      {request, response}
    end

    opts = %{
      url: url,
      scope: scope,
      generation: generation,
      req_options: [adapter: adapter, headers: [{"cookie", "extra=caller"}]]
    }

    assert {:ok, prepared} = Requester.prepare(opts)
    assert prepared.request.headers["cookie"] == ["id=account; id=root; extra=caller"]
    Store.save_cookies(scope, url, ["after=prepare; Path=/; Secure"], generation)
    assert {:ok, _} = Requester.send(prepared)
    assert_receive {:cookie, "/account/first", ["id=account; id=root; extra=caller"]}

    assert_receive {:cookie, "/account/last",
                    ["id=account; id=root; after=prepare; next=redirect; extra=caller"]}
  end

  test "omit and foreign same-origin responses cannot populate the real Store jar" do
    for {credentials, document} <- [
          {:omit, "https://seed.test/"},
          {:same_origin, "https://document.test/"}
        ] do
      scope = unique()
      generation = Store.generation(scope)

      adapter = fn request ->
        {request,
         Req.Response.new(
           status: 200,
           headers: [{"set-cookie", "rejected=1; Secure; Path=/"}],
           body: "OK"
         )}
      end

      assert {:ok, _} =
               Requester.make(%{
                 url: "https://seed.test/",
                 cookie_site: document,
                 credentials: credentials,
                 scope: scope,
                 generation: generation,
                 req_options: [adapter: adapter]
               })

      assert Store.cookie_header(scope, "https://seed.test/", generation) == nil
    end
  end

  test "same-host scheme and port changes retain auth and custom headers while same-origin narrows cookies" do
    owner = self()

    adapter = fn request ->
      send(owner, {:hop, URI.to_string(request.url), request.headers})

      response =
        if request.url.scheme == "https",
          do:
            Req.Response.new(status: 302, headers: [{"location", "http://seed.test:8080/last"}]),
          else: Req.Response.new(status: 200, body: "OK")

      {request, response}
    end

    for credentials <- [:include, :same_origin] do
      assert {:ok, _} =
               Requester.make(%{
                 url: "https://seed.test/first",
                 credentials: credentials,
                 req_options: [
                   adapter: adapter,
                   auth: {:bearer, "retained"},
                   headers: [{"x-secret", "retained"}, {"cookie", "caller=one"}]
                 ]
               })

      assert_receive {:hop, "https://seed.test/first", first}
      assert_receive {:hop, "http://seed.test:8080/last", last}
      assert first["cookie"] == ["caller=one"]
      assert last["authorization"] == ["Bearer retained"]
      assert last["x-secret"] == ["retained"]
      assert last["cookie"] == if(credentials == :include, do: ["caller=one"], else: nil)
    end
  end

  test "leaving and returning to a host does not resurrect frozen caller credentials" do
    owner = self()

    adapter = fn request ->
      send(owner, {:hop, request.url.host, request.headers})

      location =
        case {request.url.host, request.url.path} do
          {"seed.test", "/first"} -> "https://foreign.test/middle"
          {"foreign.test", _} -> "https://seed.test/last"
          _ -> nil
        end

      response =
        if location,
          do: Req.Response.new(status: 302, headers: [{"location", location}]),
          else: Req.Response.new(status: 200, body: "OK")

      {request, response}
    end

    assert {:ok, _} =
             Requester.make(%{
               url: "https://seed.test/first",
               reference_tag: "script",
               req_options: [
                 adapter: adapter,
                 auth: {:bearer, "secret"},
                 headers: [{"cookie", "caller=one"}]
               ]
             })

    assert_receive {:hop, "seed.test", _}
    assert_receive {:hop, "foreign.test", middle}
    assert_receive {:hop, "seed.test", last}

    for headers <- [middle, last] do
      refute Map.has_key?(headers, "authorization")
      refute Map.has_key?(headers, "cookie")
    end
  end

  test "equivalent wire auth and query inputs share independently of construction source and document path" do
    left = %{
      url: "https://seed.test/a",
      site: "https://seed.test/left",
      cookie_site: "https://document.test/left",
      req_options: [auth: {:bearer, "same"}, params: [q: "one"]]
    }

    right = %{
      url: "https://seed.test/a?q=one",
      site: "https://seed.test/right",
      cookie_site: "https://document.test/right",
      req_options: [headers: [{"authorization", "Bearer same"}]]
    }

    assert {:ok, first} = Requester.prepare(left)
    assert {:ok, second} = Requester.prepare(right)
    assert first.request.url == second.request.url
    assert first.request.headers == second.request.headers
    assert first.equivalence == second.equivalence
  end

  test "explicit Req plugins replace application plugins and run once for both entrypoints" do
    owner = self()

    application = fn request ->
      send(owner, :application_plugin)
      request
    end

    explicit = fn request ->
      send(owner, :explicit_plugin)
      request
    end

    Req.default_options(plugins: [application])
    adapter = fn request -> {request, Req.Response.new(status: 200, body: "OK")} end

    assert {:ok, prepared} =
             Requester.prepare(%{
               url: "https://seed.test/",
               req_options: [adapter: adapter, plugins: [explicit]]
             })

    assert {:ok, _} = Requester.send(prepared)
    assert_receive :explicit_plugin
    refute_received :application_plugin
    refute_received :explicit_plugin

    assert {:ok, _} =
             Crawler.HTTP.get("https://seed.test/", [],
               adapter: adapter,
               plugins: [explicit],
               retry: false
             )

    assert_receive :explicit_plugin
    refute_received :application_plugin
    refute_received :explicit_plugin
  end

  test "partitioned and unpartitioned duplicate cookie names retain creation order beside a caller cookie" do
    scope = unique()
    generation = Store.generation(scope)
    url = "https://third.test/asset"
    context = %{site: "https://top.test/page", navigation: false, credentials: :include}

    Store.save_cookies(
      scope,
      url,
      [
        "sid=ordinary; Path=/; Secure; SameSite=None",
        "sid=partition; Path=/; Secure; SameSite=None; Partitioned"
      ],
      generation,
      context
    )

    opts = %{
      url: url,
      scope: scope,
      generation: generation,
      cookie_site: context.site,
      req_options: [headers: [{"cookie", "extra=caller"}]]
    }

    assert {:ok, prepared} = Requester.prepare(opts)
    assert prepared.request.headers["cookie"] == ["sid=ordinary; sid=partition; extra=caller"]

    assert {:ok, other} =
             Requester.prepare(Map.put(opts, :cookie_site, "https://other.test/page"))

    assert other.request.headers["cookie"] == ["sid=ordinary; extra=caller"]
    refute prepared.equivalence == other.equivalence
  end

  test "direct HTTP applies global auth policy against its explicit document context" do
    owner = self()

    adapter = fn request ->
      send(owner, {:headers, request.headers})
      {request, Req.Response.new(status: 200, body: "OK")}
    end

    Req.default_options(
      auth: {:bearer, "global-secret"},
      headers: [{"x-secret", "global-secret"}]
    )

    assert {:ok, _} =
             Crawler.HTTP.get("https://foreign.test/", [],
               adapter: adapter,
               crawler_cookie_site: "https://seed.test/",
               retry: false
             )

    assert_receive {:headers, headers}
    refute Map.has_key?(headers, "authorization")
    refute Map.has_key?(headers, "x-secret")
  end

  test "failed preparation before binding retains no hidden scope, cookie or robots state" do
    scope = unique()

    assert {:error, {:request_preparation, :invalid_options}} =
             Requester.prepare(%{
               url: "https://seed.test/",
               scope: scope,
               req_options: [unknown_preparation_option: true]
             })

    assert_absent_scope(scope)
  end

  test "prebind preparation sends frozen credentials with live cookie and inline robots authority" do
    scope = unique()
    preparing_queue = alive_queue()
    executing_queue = alive_queue()
    owner = self()
    url = "https://seed.test/initial"

    adapter = fn request ->
      send(
        owner,
        {:bound_hop, request.url.host, request.url.path, request.options[:crawler_scope],
         request.options[:crawler_generation], request.options[:crawler_queue],
         request.options[:crawler_execution_lease], Process.get(:crawler_execution_lease),
         request.headers}
      )

      response =
        case {request.url.host, request.url.path} do
          {"seed.test", "/initial"} ->
            Req.Response.new(
              status: 302,
              headers: [
                {"location", "https://foreign.test/last"},
                {"set-cookie", "landed=seed; Path=/; Secure"}
              ]
            )

          {"foreign.test", "/robots.txt"} ->
            Req.Response.new(
              status: 200,
              body: "User-agent: *\nAllow: /\n",
              headers: [{"set-cookie", "robot=seen; Path=/; Secure; SameSite=None"}]
            )

          {"foreign.test", "/last"} ->
            Req.Response.new(status: 200, body: "OK")
        end

      {request, response}
    end

    opts = %{
      url: url,
      scope: scope,
      queue: preparing_queue,
      owner: owner,
      site: url,
      reference_tag: "script",
      modifier: AuthorityModifier,
      respect_robots: true,
      req_options: [adapter: adapter]
    }

    assert {:ok, prepared} = Requester.prepare(opts)
    assert prepared.request.options[:crawler_generation] == nil
    assert prepared.request.options[:crawler_queue] == preparing_queue
    refute Map.has_key?(:sys.get_state(Store).scopes, scope)
    assert_receive {:modifier_options, ^url}
    assert_receive {:modifier_headers, ^url}

    generation = Store.generation(scope)
    assert :ok = Store.note_enqueued(scope, generation, executing_queue)
    Store.save_cookies(scope, url, ["late=root; Path=/; Secure"], generation)

    Store.save_cookies(
      scope,
      "https://foreign.test/last",
      ["foreign=jar; Path=/; Secure; SameSite=None"],
      generation,
      %{site: url, credentials: :include, navigation: false}
    )

    deadline = Crawler.Deadline.after_ms(5000)
    context = %{scope: scope, generation: generation, queue: executing_queue}
    assert {:ok, lease} = Store.begin_execution(context, deadline)
    previous_lease = make_ref()
    Process.put(:crawler_execution_lease, previous_lease)

    try do
      injected =
        Map.merge(context, %{
          execution_lease: lease,
          deadline: deadline,
          url: "https://injected.test/",
          site: "https://injected.test/",
          cookie_site: "https://injected.test/",
          credentials: :omit,
          max_body: 0,
          respect_robots: false,
          req_options: [auth: {:bearer, "injected"}]
        })

      assert {:ok, %Req.Response{body: "OK"}} = Requester.send(prepared, injected)
      assert Process.get(:crawler_execution_lease) == previous_lease

      assert_receive {:bound_hop, "seed.test", "/initial", ^scope, ^generation, ^executing_queue,
                      ^lease, ^lease, initial_headers}

      assert initial_headers == prepared.request.headers
      assert initial_headers["authorization"] == ["Bearer frozen"]
      assert initial_headers["cookie"] == ["caller=one"]

      assert_receive {:bound_hop, "foreign.test", "/robots.txt", ^scope, ^generation,
                      ^executing_queue, ^lease, ^lease, _robots_headers}

      assert_receive {:bound_hop, "foreign.test", "/last", ^scope, ^generation, ^executing_queue,
                      ^lease, ^lease, final_headers}

      assert final_headers["cookie"] == ["foreign=jar; robot=seen"]
      refute Map.has_key?(final_headers, "authorization")
      refute_received {:modifier_options, ^url}
      refute_received {:modifier_headers, ^url}
      assert prepared.request.options[:crawler_generation] == nil
      assert prepared.request.options[:crawler_queue] == preparing_queue
    after
      Process.delete(:crawler_execution_lease)
      Store.end_execution(lease)
    end

    assert Store.cookie_header(scope, url, generation) =~ "landed=seed"

    assert {:ready, _rules} =
             Store.claim_robots(scope, "https://foreign.test", generation, executing_queue)
  end

  test "a retired generation or revoked execution lease cannot send or mutate fresh cookies" do
    owner = self()

    for failure <- [:generation, :lease] do
      scope = unique()
      queue = alive_queue()

      adapter = fn request ->
        send(owner, :stale_transport)

        {request,
         Req.Response.new(
           status: 200,
           body: "OK",
           headers: [{"set-cookie", "stale=one; Path=/; Secure"}]
         )}
      end

      assert {:ok, prepared} =
               Requester.prepare(%{
                 url: "https://seed.test/",
                 scope: scope,
                 req_options: [adapter: adapter]
               })

      generation = Store.generation(scope)
      :ok = Store.note_enqueued(scope, generation, queue)
      context = %{scope: scope, generation: generation, queue: queue}

      context =
        case failure do
          :generation ->
            Store.drop_scope(scope)
            context

          :lease ->
            {:ok, lease} = Store.begin_execution(context, Crawler.Deadline.after_ms(5000))
            :ok = Store.end_execution(lease)
            Map.put(context, :execution_lease, lease)
        end

      assert {:error, :stale} = Requester.send(prepared, context)
      refute_received :stale_transport
      assert Process.get(:crawler_execution_lease) == nil
      fresh = Store.generation(scope)
      assert Store.cookie_header(scope, "https://seed.test/", fresh) == nil
    end
  end

  test "revocation during transport discards stale response cookies and redirect work" do
    scope = unique()
    queue = alive_queue()
    owner = self()

    adapter = fn request ->
      send(owner, :one_transport)
      Store.drop_scope(scope)

      {request,
       Req.Response.new(
         status: 302,
         headers: [{"location", "/last"}, {"set-cookie", "stale=one; Path=/; Secure"}]
       )}
    end

    assert {:ok, prepared} =
             Requester.prepare(%{
               url: "https://seed.test/first",
               scope: scope,
               respect_robots: true,
               req_options: [adapter: adapter]
             })

    generation = Store.generation(scope)
    :ok = Store.note_enqueued(scope, generation, queue)
    context = %{scope: scope, generation: generation, queue: queue}
    deadline = Crawler.Deadline.after_ms(5000)
    {:ok, lease} = Store.begin_execution(context, deadline)

    try do
      assert {:error, :stale} =
               Requester.send(
                 prepared,
                 Map.merge(context, %{execution_lease: lease, deadline: deadline})
               )

      assert_receive :one_transport
      refute_received :one_transport
      assert Process.get(:crawler_execution_lease) == nil
    after
      Store.end_execution(lease)
    end

    fresh = Store.generation(scope)
    assert Store.cookie_header(scope, "https://seed.test/", fresh) == nil
    refute Map.has_key?(:sys.get_state(Store).robots, scope)
  end

  test "prebind and sibling queue equivalence is run-local and cannot permit cross-scope reuse" do
    scope = unique()
    other_scope = unique()
    left_queue = alive_queue()
    right_queue = alive_queue()
    url = "https://seed.test/initial"

    opts = %{
      url: url,
      site: url,
      cookie_site: "https://document.test/page",
      reference_tag: "script"
    }

    assert {:ok, prebind} = Requester.prepare(opts)
    generation = Store.generation(scope)
    other_generation = Store.generation(other_scope)
    :ok = Store.note_enqueued(scope, generation, left_queue)
    :ok = Store.note_enqueued(scope, generation, right_queue)

    Store.save_cookies(
      scope,
      url,
      ["future=left; Path=/future; Secure; SameSite=None"],
      generation
    )

    Store.save_cookies(
      other_scope,
      url,
      ["future=right; Path=/future; Secure; SameSite=None"],
      other_generation
    )

    assert {:ok, left} =
             Requester.prepare(
               Map.merge(opts, %{
                 scope: scope,
                 generation: generation,
                 queue: left_queue,
                 execution_lease: make_ref()
               })
             )

    assert {:ok, right} =
             Requester.prepare(
               Map.merge(opts, %{
                 scope: scope,
                 generation: generation,
                 queue: right_queue,
                 execution_lease: make_ref()
               })
             )

    assert {:ok, other} =
             Requester.prepare(
               Map.merge(opts, %{scope: other_scope, generation: other_generation})
             )

    assert prebind.equivalence == left.equivalence
    assert left.equivalence == right.equivalence
    assert left.equivalence == other.equivalence
    assert left.context.cookie_partition == scope
    assert other.context.cookie_partition == other_scope

    assert Store.cookie_header(scope, "https://seed.test/future", generation) !=
             Store.cookie_header(other_scope, "https://seed.test/future", other_generation)

    identity = %Crawler.Job.Identity{representation: left.equivalence, interpretation: :document}
    attrs = %{logical_id: url, logical_key: url, prepared_request: left}
    job = Crawler.Job.new(:fetch, {scope, generation, left_queue}, attrs)
    sibling = Crawler.Job.new(:fetch, {scope, generation, right_queue}, attrs)

    separate =
      Crawler.Job.new(:fetch, {other_scope, other_generation, nil}, %{
        attrs
        | prepared_request: other
      })

    restarted_generation = {elem(generation, 0), scope, make_ref()}
    restarted = Crawler.Job.new(:fetch, {scope, restarted_generation, nil}, attrs)
    charge = %{metadata: 0, payload: 0}

    assert {:accepted, accepted, frontier} =
             Crawler.Frontier.admit(Crawler.Frontier.new(), job, identity, charge)

    assert {:existing, _, frontier} = Crawler.Frontier.admit(frontier, sibling, identity, charge)

    assert {:accepted, separate, frontier} =
             Crawler.Frontier.admit(frontier, separate, identity, charge)

    assert {:accepted, restarted, _frontier} =
             Crawler.Frontier.admit(frontier, restarted, identity, charge)

    refute accepted.representation_id == separate.representation_id
    refute accepted.representation_id == restarted.representation_id
  end

  test "a nil-scope root keeps its frozen first hop while each bound run supplies its own redirect jar" do
    owner = self()
    url = "https://seed.test/initial"

    adapter = fn request ->
      send(
        owner,
        {:run_cookie, request.options[:crawler_scope], request.url.path,
         request.headers["cookie"]}
      )

      response =
        if request.url.path == "/initial",
          do:
            Req.Response.new(
              status: 302,
              headers: [{"location", "/future"}, {"set-cookie", "arrived=one; Path=/; Secure"}]
            ),
          else: Req.Response.new(status: 200, body: "OK")

      {request, response}
    end

    assert {:ok, prepared} =
             Requester.prepare(%{
               url: url,
               site: url,
               req_options: [adapter: adapter, headers: [{"cookie", "caller=one"}]]
             })

    assert prepared.context.cookie_partition == nil

    for tenant <- ["left", "right"] do
      scope = unique()
      queue = alive_queue()
      generation = Store.generation(scope)
      :ok = Store.note_enqueued(scope, generation, queue)
      Store.save_cookies(scope, url, ["tenant=#{tenant}; Path=/future; Secure"], generation)

      assert {:ok, %Req.Response{body: "OK"}} =
               Requester.send(prepared, %{scope: scope, generation: generation, queue: queue})

      assert_receive {:run_cookie, ^scope, "/initial", ["caller=one"]}
      expected = "tenant=#{tenant}; arrived=one; caller=one"
      assert_receive {:run_cookie, ^scope, "/future", [^expected]}

      assert Store.cookie_header(scope, "https://seed.test/future", generation) ==
               "tenant=#{tenant}; arrived=one"
    end

    assert prepared.request.options[:crawler_scope] == nil
    assert prepared.request.headers["cookie"] == ["caller=one"]
    refute_received {:run_cookie, _, _, _}
  end

  test "prebind preparation followed by rejected frontier admission leaves no hidden metadata" do
    scope = unique()
    url = "https://seed.test/initial"
    assert {:ok, prepared} = Requester.prepare(%{url: url, scope: scope})
    generation = {make_ref(), scope, make_ref()}

    job =
      Crawler.Job.new(:fetch, {scope, generation, nil}, %{
        logical_id: url,
        logical_key: url,
        prepared_request: prepared
      })

    identity = %Crawler.Job.Identity{
      representation: prepared.equivalence,
      interpretation: :document
    }

    frontier = Crawler.Frontier.new(%{max_frontier_bytes: 1})

    assert {:limited, :max_frontier_bytes, _frontier} =
             Crawler.Frontier.admit(frontier, job, identity, %{metadata: 0, payload: 0})

    assert_absent_scope(scope)
  end

  test "shared-scope preparation reads current cookies before a new queue is registered" do
    scope = unique()
    generation = Store.generation(scope)
    old_queue = alive_queue()
    new_queue = alive_queue()
    :ok = Store.note_enqueued(scope, generation, old_queue)
    url = "https://seed.test/start"
    Store.save_cookies(scope, url, ["session=shared; Path=/; Secure"], generation)

    assert {:ok, prepared} = Requester.prepare(%{url: url, scope: scope, queue: new_queue})
    assert prepared.request.headers["cookie"] == ["session=shared"]
    assert prepared.request.options[:crawler_generation] == nil
    assert prepared.request.options[:crawler_queue] == new_queue
    assert Store.generation(scope) == generation
    refute Map.has_key?(:sys.get_state(Store).scopes[scope].work, new_queue)
  end

  test "cookie proof binding changes only context and preserves the initial request and modifiers" do
    opts = cookie_proof_fixture()

    initial =
      opts
      |> Map.drop([:scope, :generation])
      |> Map.merge(%{modifier: AuthorityModifier, owner: self()})

    assert {:ok, prepared} = Requester.prepare(initial)
    assert_receive {:modifier_options, _}
    assert_receive {:modifier_headers, _}
    assert prepared.request.headers["cookie"] == ["caller=one"]

    Store.save_cookies(opts.scope, opts.url, ["late=root; Path=/; Secure"], opts.generation)

    assert {:ok, observation} =
             Store.validate_cookie_proof(
               opts.scope,
               opts.generation,
               proof_context(opts),
               :unbound
             )

    bound = Requester.bind_cookie_proof(prepared, observation.proof)
    assert bound.context.cookie_proof == observation.proof
    assert bound.request === prepared.request
    assert bound.equivalence === prepared.equivalence
    assert bound.context.cookie_partition == prepared.context.cookie_partition

    assert {:ok, response} =
             Requester.send(bound, %{scope: opts.scope, generation: opts.generation})

    assert response.body == "late=root; caller=one"
    assert_receive {:proof_hop, "/start", ["caller=one"]}
    assert_receive {:proof_hop, "/private", ["late=root; caller=one"]}
    assert Requester.reuse_disposition(response).disposition == :candidate
    refute_received {:modifier_options, _}
    refute_received {:modifier_headers, _}
  end

  test "stable real Req redirect requests share initial equality and the same proved disposition across goals" do
    opts = cookie_proof_fixture()
    assert {:ok, _} = proof_mutate(opts, "A")
    assert {:ok, first} = Requester.prepare(opts)
    assert {:ok, other_goal} = Requester.prepare(Map.put(opts, :js_goal, :module))
    assert first.equivalence == other_goal.equivalence
    assert first.context.cookie_proof == other_goal.context.cookie_proof

    for prepared <- [first, other_goal] do
      assert {:ok, response} = Requester.send(prepared)
      assert response.body == "id=A"

      assert %ReuseDisposition{
               dependency: {:redirect_jar, proof},
               disposition: :candidate,
               reason: nil
             } = Requester.reuse_disposition(response)

      assert proof == first.context.cookie_proof

      assert {:ok, %{verdict: :current}} =
               Store.validate_cookie_proof(
                 opts.scope,
                 opts.generation,
                 proof_context(opts),
                 proof
               )
    end
  end

  test "same initial Cookie with changed future path cookies has a different proof and cannot attest an earlier preparation" do
    opts = cookie_proof_fixture()
    assert {:ok, _} = proof_mutate(opts, "A")
    assert {:ok, first} = Requester.prepare(opts)
    assert {:ok, response_a} = Requester.send(first)
    assert response_a.body == "id=A"
    assert Requester.reuse_disposition(response_a).disposition == :candidate

    assert {:ok, _} = proof_mutate(opts, "B")
    assert {:ok, second} = Requester.prepare(opts)
    assert Req.Request.get_header(first.request, "cookie") == []
    assert Req.Request.get_header(second.request, "cookie") == []
    assert first.request.headers == second.request.headers
    assert first.equivalence == second.equivalence
    refute first.context.cookie_proof == second.context.cookie_proof

    assert {:ok, %{verdict: :changed}} =
             Store.validate_cookie_proof(
               opts.scope,
               opts.generation,
               proof_context(opts),
               first.context.cookie_proof
             )

    assert {:ok, response_b} = Requester.send(second)
    assert response_b.body == "id=B"
    assert Requester.reuse_disposition(response_b).disposition == :candidate

    assert {:ok, delayed} = Requester.send(first)
    assert delayed.body == "id=B"

    assert %ReuseDisposition{
             dependency: {:redirect_jar, old_proof},
             disposition: :private,
             reason: :cookie_state_changed
           } = Requester.reuse_disposition(delayed)

    assert old_proof == first.context.cookie_proof
  end

  test "identical and rejected own Set-Cookie updates keep a stable redirect proof" do
    for path <- ["/start-noop-cookie", "/start-rejected-cookie"] do
      opts = cookie_proof_fixture()
      assert {:ok, _} = proof_mutate(opts, "A")
      assert {:ok, prepared} = Requester.prepare(%{opts | url: "https://seed.test" <> path})
      assert {:ok, response} = Requester.send(prepared)
      assert response.body == "id=A"

      assert %ReuseDisposition{disposition: :candidate, dependency: {:redirect_jar, proof}} =
               Requester.reuse_disposition(response)

      assert proof == prepared.context.cookie_proof

      assert {:ok, %{verdict: :current}} =
               Store.validate_cookie_proof(
                 opts.scope,
                 opts.generation,
                 proof_context(opts),
                 proof
               )
    end
  end

  test "own Set-Cookie before or after a jar-dependent hop prevents reuse without changing live redirect credentials" do
    for path <- ["/start-own-cookie", "/start-landing-cookie"] do
      opts = cookie_proof_fixture()
      assert {:ok, _} = proof_mutate(opts, "A")
      assert {:ok, prepared} = Requester.prepare(%{opts | url: "https://seed.test" <> path})
      assert {:ok, response} = Requester.send(prepared)
      assert response.body == if(path == "/start-own-cookie", do: "id=B", else: "id=A")

      assert %ReuseDisposition{
               dependency: {:redirect_jar, proof},
               disposition: :private,
               reason: :cookie_state_changed
             } = Requester.reuse_disposition(response)

      assert proof == prepared.context.cookie_proof

      assert {:ok, %{verdict: :changed}} =
               Store.validate_cookie_proof(
                 opts.scope,
                 opts.generation,
                 proof_context(opts),
                 proof
               )
    end
  end

  test "a direct 200 keeps initial-only reuse when an old proof or its own Set-Cookie changes the jar" do
    opts = cookie_proof_fixture()
    direct_opts = %{opts | url: "https://seed.test/direct-cookie"}
    assert {:ok, _} = proof_mutate(opts, "A")
    assert {:ok, prepared} = Requester.prepare(direct_opts)
    assert {:ok, _} = proof_mutate(opts, "C")
    assert {:ok, response} = Requester.send(prepared)
    assert response.body == "direct"

    assert %ReuseDisposition{dependency: :initial, disposition: :candidate, reason: nil} =
             Requester.reuse_disposition(response)

    assert Store.cookie_header(opts.scope, "https://seed.test/private", opts.generation) == "id=B"
  end

  test "omit has no future jar dependency and rejects own response cookies" do
    opts = cookie_proof_fixture()
    assert {:ok, _} = proof_mutate(opts, "A")

    assert {:ok, prepared} =
             Requester.prepare(
               Map.merge(opts, %{url: "https://seed.test/start-own-cookie", credentials: :omit})
             )

    assert {:ok, response} = Requester.send(prepared)
    assert response.body == "none"

    assert %ReuseDisposition{dependency: :initial, disposition: :candidate} =
             Requester.reuse_disposition(response)

    assert Store.cookie_header(opts.scope, "https://seed.test/private", opts.generation) == "id=A"
  end

  test "real expiration between the frozen first hop and redirect invalidates the admitted proof" do
    opts = cookie_proof_fixture()

    Store.save_cookies(
      opts.scope,
      opts.url,
      ["id=expires; Path=/private; Secure; Max-Age=1"],
      opts.generation
    )

    assert {:ok, prepared} = Requester.prepare(%{opts | url: "https://seed.test/start-expiring"})
    assert {:ok, response} = Requester.send(prepared)
    assert response.body == "none"

    assert %ReuseDisposition{
             dependency: {:redirect_jar, proof},
             disposition: :private,
             reason: :cookie_state_changed
           } = Requester.reuse_disposition(response)

    assert proof == prepared.context.cookie_proof
    assert Store.cookie_header(opts.scope, "https://seed.test/private", opts.generation) == nil
  end

  test "reuse receipts redact proofs and missing or invalid receipts fail closed" do
    opts = cookie_proof_fixture()
    assert {:ok, prepared} = Requester.prepare(opts)
    assert {:ok, response} = Requester.send(prepared)
    receipt = Requester.reuse_disposition(response)
    assert inspect(receipt) == "#Crawler.Fetcher.Requester.PreparedRequest.ReuseDisposition<...>"
    refute inspect(response) =~ inspect(prepared.context.cookie_proof)
    assert Requester.reuse_disposition(Req.Response.new()).disposition == :private

    invalid = %ReuseDisposition{dependency: :unknown, disposition: :candidate}
    response = Req.Response.put_private(response, :crawler_reuse, invalid)
    assert Requester.reuse_disposition(response).disposition == :private
  end

  defp cookie_proof_fixture do
    scope = unique()
    generation = Store.generation(scope)
    name = {__MODULE__, make_ref()}
    owner = self()

    Req.Test.stub(name, fn conn ->
      send(owner, {:proof_hop, conn.request_path, Plug.Conn.get_req_header(conn, "cookie")})
      cookie = Enum.join(Plug.Conn.get_req_header(conn, "cookie"), "; ")
      body = if cookie == "", do: "none", else: cookie

      case conn.request_path do
        "/mutate/" <> value ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "id=#{value}; Path=/private; Secure")
          |> Plug.Conn.send_resp(200, "updated")

        "/direct-cookie" ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "id=B; Path=/private; Secure")
          |> Plug.Conn.send_resp(200, "direct")

        "/private/landing" ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "landed=one; Path=/private; Secure")
          |> Plug.Conn.send_resp(200, body)

        "/private" ->
          Plug.Conn.send_resp(conn, 200, body)

        path ->
          if path == "/start-expiring", do: Process.sleep(1100)

          conn =
            case path do
              "/start-own-cookie" ->
                Plug.Conn.put_resp_header(conn, "set-cookie", "id=B; Path=/private; Secure")

              "/start-noop-cookie" ->
                Plug.Conn.put_resp_header(conn, "set-cookie", "id=A; Path=/private; Secure")

              "/start-rejected-cookie" ->
                Plug.Conn.put_resp_header(
                  conn,
                  "set-cookie",
                  "id=B; Domain=other.test; Path=/private; Secure"
                )

              _ ->
                conn
            end

          landing = if path == "/start-landing-cookie", do: "/private/landing", else: "/private"
          conn |> Plug.Conn.put_resp_header("location", landing) |> Plug.Conn.send_resp(302, "")
      end
    end)

    %{
      scope: scope,
      generation: generation,
      url: "https://seed.test/start",
      site: "https://seed.test/",
      cookie_site: "https://seed.test/",
      reference_tag: "script",
      req_options: [plug: {Req.Test, name}]
    }
  end

  defp proof_mutate(opts, value),
    do: Requester.make(%{opts | url: "https://seed.test/mutate/" <> value})

  defp proof_context(opts) do
    %{site: opts.cookie_site, navigation: false, credentials: opts[:credentials] || :include}
  end

  defp assert_absent_scope(scope) do
    state = :sys.get_state(Store)
    refute Map.has_key?(state.scopes, scope)
    refute Map.has_key?(state.cookies, scope)
    refute Map.has_key?(state.cookie_outcomes, scope)
    refute Map.has_key?(state.robots, scope)
    assert :ets.lookup(Crawler.Store.Authority, scope) == []
  end

  defp alive_queue do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp unique, do: "prepared-#{System.unique_integer([:positive])}"
end
