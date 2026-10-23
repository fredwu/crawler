defmodule Crawler.Export.ProducerTest do
  use ExUnit.Case, async: false

  import Crawler.TestHelpers, only: [wait: 1]

  alias Crawler.Fetcher
  alias Crawler.Options
  alias Crawler.Parser.CssSheets
  alias Crawler.Store
  alias Crawler.Store.Page

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    File.chmod!(root, 0o700)
    Req.Test.set_req_test_to_shared()
    scope = make_ref()

    opts = %{
      url: "https://producer.test/root",
      scope: scope,
      save_to: Path.join(root, "archive"),
      req_options: [plug: {Req.Test, __MODULE__}, retry: false],
      respect_robots: false,
      max_body: 1_048_576,
      max_analysis_bytes: 16_000_000,
      max_manifest_bytes: 4_194_304,
      workers: 2,
      interval: 0,
      retries: 0
    }

    on_exit(fn ->
      Store.dispose_scope(scope)
      Req.Test.set_req_test_to_private()
    end)

    %{root: root, opts: opts}
  end

  test "queued cyclic pages publish local bindings through the automatic finalizer", c do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:requested, conn.request_path})

      body =
        case conn.request_path do
          "/root" -> ~s|<a href="/child#next">child</a>|
          "/child" -> ~s|<a href="/root#back">root</a>|
        end

      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, body)
    end)

    assert {:ok, owned} = Crawler.crawl(c.opts.url, c.opts)
    on_exit(fn -> Crawler.stop(owned) end)

    wait(fn ->
      assert {:ok, %{state: :ready}} = Crawler.export_status(owned)
      refute Crawler.running?(owned)
    end)

    resources = manifest(c)["resources"]
    assert length(resources) >= 2

    assert MapSet.new(resources, & &1["url"]) ==
             MapSet.new([c.opts.url, "https://producer.test/child"])

    Enum.each(resources, fn resource ->
      output = File.read!(Path.join([c.root, "archive", resource["path"]]))
      assert output =~ "#"

      for [_, relative] <-
            Regex.scan(~r/href="(resources\/[^"#]+|[^\/:"#]+\.html)(?:#[^"]*)?"/, output) do
        assert File.regular?(Path.join([c.root, "archive", "resources", Path.basename(relative)]))
      end
    end)

    assert_receive {:requested, "/root"}
    assert_receive {:requested, "/child"}
    refute_receive {:requested, _}

    for url <- [c.opts.url, "https://producer.test/child"] do
      assert %Page{body: nil, opts: nil, processed: true} = Store.find({url, c.opts.scope})
    end

    state = :sys.get_state(Store)
    assert state.source_cache_bytes > 0

    assert state.resources.used + state.source_cache_bytes <=
             Options.assign_defaults(c.opts).max_retained_bytes
  end

  test "crawl_now keeps parsed discovery despite a caller-supplied direct mode", c do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:requested, conn.request_path})
      body = if conn.request_path == "/root", do: ~s|<a href="/child">child</a>|, else: "child"
      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, body)
    end)

    opts = Options.assign_defaults(Map.put(c.opts, :discovery_mode, :fetch))
    assert %Page{} = page = Crawler.crawl_now(opts)
    assert page.interpretation.opts.discovery_mode == :parse
    assert_receive {:requested, "/root"}
    wait(fn -> assert {:ok, %{state: :ready}} = Store.export_status(page.opts) end)
    assert_receive {:requested, "/child"}
    assert length(manifest(c)["resources"]) == 2
    assert :ok = Store.release_page(page)
  end

  test "direct fetch stages safe online references without dispatch or parser callbacks", c do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:requested, conn.request_path})
      assert conn.request_path == "/root"
      body = ~s|<a href="/child#next">child</a>|
      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, body)
    end)

    assert %Page{} = page = Fetcher.fetch(Options.assign_defaults(c.opts))
    assert page.body == ~s|<a href="/child#next">child</a>|
    assert page.opts.content_type =~ "text/html"
    assert page.opts.store == nil
    assert is_reference(page.credit.return_token)
    assert_receive {:requested, "/root"}
    wait(fn -> assert {:ok, %{state: :ready}} = Store.export_status(page.opts) end)
    refute_receive {:requested, "/child"}
    [resource] = manifest(c)["resources"]

    assert File.read!(Path.join([c.root, "archive", resource["path"]])) =~
             "https://producer.test/child#next"

    assert %Page{body: nil, opts: nil} = Store.find({c.opts.url, c.opts.scope})
    assert :ok = Store.release_page(page)
  end

  test "direct stylesheet imports do not require undispatched children to become ready", c do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:requested, conn.request_path})
      assert conn.request_path == "/root"
      body = ~s|@import "child.css";a{background:url(pic.png)}|
      conn |> Plug.Conn.put_resp_content_type("text/css") |> Plug.Conn.resp(200, body)
    end)

    opts = Options.assign_defaults(Map.merge(c.opts, %{html_tag: "link", mode: :stylesheet}))
    assert %Page{} = page = Fetcher.fetch(opts)
    assert_receive {:requested, "/root"}
    wait(fn -> assert {:ok, %{state: :ready}} = Store.export_status(page.opts) end)
    refute_receive {:requested, _}
    [resource] = manifest(c)["resources"]
    output = File.read!(Path.join([c.root, "archive", resource["path"]]))
    assert output =~ "https://producer.test/child.css"
    assert output =~ "https://producer.test/pic.png"
  end

  test "failed direct targets do not drain parsed CSS discovery", c do
    parent = self()
    Req.Test.stub(__MODULE__, &Plug.Conn.resp(&1, 503, "unavailable"))
    Code.ensure_loaded!(CssSheets)
    :erlang.trace_pattern({CssSheets, :settle, 1}, true, [:local])

    try do
      for {mode, path} <- [{:fetch, "/direct-failure"}, {:parse, "/parsed-failure"}] do
        task =
          Task.async(fn ->
            :erlang.trace(self(), true, [:call, :set_on_spawn, {:tracer, parent}])

            opts =
              Options.assign_defaults(%{
                c.opts
                | url: "https://producer.test" <> path,
                  save_to: nil
              })

            if mode == :fetch, do: Fetcher.fetch(opts), else: Crawler.crawl_now(opts)
          end)

        assert {:error, _} = Task.await(task)

        if mode == :fetch do
          refute_receive {:trace, _, :call, {CssSheets, :settle, _}}
        else
          assert_receive {:trace, _, :call, {CssSheets, :settle, [_]}}
        end
      end
    after
      :erlang.trace_pattern({CssSheets, :settle, 1}, false, [:local])
    end
  end

  test "managed UTF16 feed ingestion releases its Document phase before staging", c do
    parent = self()

    source =
      "<?xml version=\"1.0\"?><rss><channel><item><title>界</title><link>https://producer.test/child</link></item></channel></rss>"

    wire = :unicode.characters_to_binary(source, :utf8, {:utf16, :little})

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:requested, conn.request_path})

      {type, body} =
        if conn.request_path == "/root",
          do: {"application/rss+xml", wire},
          else: {"text/html", "child"}

      conn |> Plug.Conn.put_resp_header("content-type", type) |> Plug.Conn.resp(200, body)
    end)

    assert %Page{} = page = Crawler.crawl_now(Options.assign_defaults(c.opts))
    assert length(page.credit.retained) == 3
    assert length(Enum.uniq(page.credit.retained)) == 3
    assert page.body =~ "界"
    assert page.analysis.stats.scans == %{xml: 1}
    assert page.interpretation.collection.control_document == true

    assert page.interpretation.collection.budget.peak >=
             page.interpretation.collection.budget.retained

    assert_receive {:requested, "/root"}
    assert_receive {:requested, "/child"}, 2_000
    wait(fn -> assert {:ok, %{state: :ready}} = Store.export_status(page.opts) end)
    assert length(manifest(c)["resources"]) == 2
    assert :ok = Store.release_page(page)
  end

  for body_limit <- [nil, 1_048_576] do
    test "an admitted CSS settlement with body limit #{inspect(body_limit)} refreshes staged metadata before automatic publication",
         c do
      body_limit = unquote(body_limit)
      parent = self()

      css_site(parent)

      opts = c.opts |> Map.delete(:max_body) |> Map.put(:assets, ["css", "images"])
      opts = if body_limit, do: Map.put(opts, :max_body, body_limit), else: opts
      assert {:ok, owned} = Crawler.crawl(c.opts.url, opts)
      on_exit(fn -> Crawler.stop(owned) end)
      wait(fn -> assert {:ok, %{state: :ready}} = Crawler.export_status(owned) end)
      assert_receive {:requested, "/shown.png"}
      refute_receive {:requested, "/fallback.png"}

      state = :sys.get_state(Store)
      frontier = state.scheduler.frontier

      assert Enum.any?(frontier.jobs, fn {_id, record} ->
               record.job.kind == :css_settlement and record.outcome.status == :succeeded
             end)

      resources = manifest(c)["resources"]
      assert Enum.any?(resources, &(&1["url"] == "https://producer.test/shown.png"))
      css = Enum.find(resources, &(&1["url"] == "https://producer.test/app.css"))
      output = File.read!(Path.join([c.root, "archive", css["path"]]))
      assert output =~ "var(--bg"

      assert [_, imported] = Regex.run(~r/@import "\.\/([^"]+)"/, output)
      tokens = Enum.find(resources, &(Path.basename(&1["path"]) == imported))

      picture = Enum.find(resources, &(&1["url"] == "https://producer.test/shown.png"))
      tokens_output = File.read!(Path.join([c.root, "archive", tokens["path"]]))
      assert tokens_output =~ Path.basename(picture["path"])
      assert File.read!(Path.join([c.root, "archive", picture["path"]])) == "shown"
    end
  end

  test "a body-limited CSS image stays online without an invented local artifact", c do
    css_site(self(), :binary.copy("a", c.opts.max_body + 1))
    assert {:ok, owned} = Crawler.crawl(c.opts.url, Map.put(c.opts, :assets, ["css", "images"]))
    on_exit(fn -> Crawler.stop(owned) end)
    wait(fn -> assert {:ok, %{state: :ready}} = Crawler.export_status(owned) end)
    assert_receive {:requested, "/shown.png"}
    resources = manifest(c)["resources"]
    refute Enum.any?(resources, &(&1["url"] == "https://producer.test/shown.png"))
    tokens = Enum.find(resources, &(&1["url"] == "https://producer.test/tokens.css"))
    output = File.read!(Path.join([c.root, "archive", tokens["path"]]))
    assert output =~ "https://producer.test/shown.png"
    state = :sys.get_state(Store)

    assert Enum.any?(state.scheduler.frontier.jobs, fn {_id, row} ->
             row.job.logical_key == "https://producer.test/shown.png" and
               row.outcome.status == :limited and
               row.outcome.reason == {:limit, :max_body}
           end)

    assert {:ok, %{reported_limit: {:limit, _}}} = Crawler.export_status(owned)

    assert state.resources.used + state.source_cache_bytes <=
             Options.assign_defaults(c.opts).max_retained_bytes
  end

  test "CSS refresh keeps an ordinary navigation bound before a cookie change", c do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:cookie_request, conn.request_path, Plug.Conn.get_req_header(conn, "cookie")})

      {type, body, cookie} =
        case conn.request_path do
          "/root" ->
            {"text/html",
             ~s|<a href="/child#stable">child</a><link rel="stylesheet" href="app.css">|,
             "session=A; Path=/"}

          "/child" ->
            {"text/html", "child", nil}

          "/app.css" ->
            {"text/css", ~s|@import "tokens.css";a{background:var(--bg)}|, nil}

          "/tokens.css" ->
            {"text/css", ":root{--bg:url(shown.png)}", "session=B; Path=/"}

          "/shown.png" ->
            {"image/png", "shown", nil}
        end

      conn = if cookie, do: Plug.Conn.put_resp_header(conn, "set-cookie", cookie), else: conn
      conn |> Plug.Conn.put_resp_content_type(type) |> Plug.Conn.resp(200, body)
    end)

    opts = c.opts |> Map.delete(:max_body) |> Map.put(:assets, ["css", "images"])
    assert {:ok, owned} = Crawler.crawl(c.opts.url, opts)
    on_exit(fn -> Crawler.stop(owned) end)
    wait(fn -> assert {:ok, %{state: :ready}} = Crawler.export_status(owned) end)
    assert_receive {:cookie_request, "/child", ["session=A"]}
    assert_receive {:cookie_request, "/shown.png", ["session=B"]}
    refute_receive {:cookie_request, "/child", _}

    state = :sys.get_state(Store)

    children =
      Enum.filter(state.scheduler.frontier.jobs, fn {_target, row} ->
        row.job.logical_key == "https://producer.test/child"
      end)

    assert [{child, %{outcome: %{status: :succeeded}}}] = children
    export = state.exports[{owned.scope, owned.generation}]
    child_id = export.target_contexts[child].public_id
    resource = Enum.find(manifest(c)["resources"], &(&1["id"] == child_id))
    root = Enum.find(manifest(c)["resources"], &(&1["url"] == opts.url))
    output = File.read!(Path.join([c.root, "archive", root["path"]]))
    assert output =~ Path.basename(resource["path"]) <> "#stable"
  end

  defp css_site(parent, picture \\ "shown") do
    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:requested, conn.request_path})

      {type, body} =
        case conn.request_path do
          "/root" ->
            {"text/html", ~s|<link rel="stylesheet" href="app.css">|}

          "/app.css" ->
            {"text/css", ~s|@import "tokens.css";a{background:var(--bg,url(fallback.png))}|}

          "/tokens.css" ->
            {"text/css", ":root{--bg:url(shown.png)}"}

          "/shown.png" ->
            {"image/png", picture}
        end

      conn |> Plug.Conn.put_resp_content_type(type) |> Plug.Conn.resp(200, body)
    end)
  end

  defp manifest(c),
    do: c.root |> Path.join("archive/manifest.json") |> File.read!() |> Jason.decode!()
end
