defmodule Crawler.Export.DiscoveryPolicyTest do
  use ExUnit.Case, async: false

  import Crawler.TestHelpers, only: [wait: 1]
  import Crawler.ManagedSnapshotHelpers, only: [ready_export: 1]

  alias Crawler.Fetcher
  alias Crawler.Options
  alias Crawler.Store
  alias Crawler.Store.Page

  defmodule ObservedParser do
    @moduledoc false

    def parse(%Crawler.Store.Page{} = page) do
      observer = page.opts.policy_observer
      send(observer, {:parser_called, page.url, self(), page.target_handle})

      if page.url == page.opts.policy_root do
        receive do
          {:continue_parser, target} when target == page.target_handle -> :ok
        end
      end

      Crawler.Parser.parse(page)
    end

    def parse(other), do: Crawler.Parser.parse(other)
  end

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    File.chmod!(root, 0o700)
    Req.Test.set_req_test_to_shared()
    scope = make_ref()
    url = "https://discovery-policy.test/root"

    opts =
      Options.assign_defaults(%{
        url: url,
        scope: scope,
        save_to: Path.join(root, "archive"),
        req_options: [plug: {Req.Test, __MODULE__}, retry: false],
        respect_robots: false,
        cookie_navigation: false,
        parser: ObservedParser,
        policy_observer: self(),
        policy_root: url,
        max_body: Options.assign_defaults(%{}).max_body,
        max_analysis_bytes: 16_000_000,
        max_manifest_bytes: 4_194_304,
        workers: 2,
        interval: 0,
        retries: 0
      })

    on_exit(fn ->
      Store.dispose_scope(scope)
      Req.Test.set_req_test_to_private()
    end)

    %{root: root, opts: opts}
  end

  for first <- [:fetch, :parse] do
    test "#{first} first shares physical facts but preserves each discovery policy", c do
      parent = self()
      source = ~s|<a href="/child#next">café</a>|
      wire = <<255, 254>> <> :unicode.characters_to_binary(source, :utf8, {:utf16, :little})

      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, {:requested, conn.request_path, self()})

        case conn.request_path do
          "/root" ->
            receive do
              :respond -> :ok
            end

            conn
            |> Plug.Conn.put_resp_header("content-type", "text/html; charset=utf-16le")
            |> Plug.Conn.resp(200, wire)

          "/child" ->
            conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, "child")
        end
      end)

      first = unquote(first)
      second = if first == :fetch, do: :parse, else: :fetch
      first_task = start_call(first, c.opts)
      assert_receive {:requested, "/root", responder}, 2_000
      second_task = start_call(second, c.opts)

      wait(fn ->
        jobs = root_jobs(c.opts)
        assert length(jobs) == 2
        assert MapSet.new(jobs, & &1.opts.discovery_mode) == MapSet.new([:fetch, :parse])
        assert length(Enum.uniq_by(jobs, & &1.representation_id)) == 1
        assert length(Enum.uniq_by(jobs, & &1.interpretation_id)) == 2
      end)

      send(responder, :respond)
      assert_receive {:parser_called, url, parser, parsed_target}, 2_000
      assert url == c.opts.url
      if first == :parse, do: send(parser, {:continue_parser, parsed_target})
      assert_receive {:call_result, :fetch, direct_caller, direct}, call_timeout(c.opts)
      assert %Page{} = direct
      assert direct.body == source
      assert direct.interpretation.opts.discovery_mode == :fetch
      refute direct.target_handle == parsed_target

      if first == :fetch do
        refute_received {:requested, "/child", _}
        assert {:ok, %{state: :admitting}} = Store.export_status(direct.opts)
        send(parser, {:continue_parser, parsed_target})
      end

      assert_receive {:call_result, :parse, parsed_caller, %Page{} = parsed}, 2_000
      assert parsed.body == source
      assert parsed.interpretation.opts.discovery_mode == :parse
      assert parsed.target_handle == parsed_target
      assert_shared_source(direct, parsed)

      assert_receive {:requested, "/child", _}, 2_000
      assert_receive {:parser_called, child_url, _, _}, 2_000
      assert child_url == "https://discovery-policy.test/child"
      wait(fn -> assert {:ok, %{state: :ready}} = Store.export_status(parsed.opts) end)
      assert_separate_artifacts(c, direct, parsed)
      refute_receive {:requested, _, _}
      refute_receive {:parser_called, _, _, _}

      for caller <- [direct_caller, parsed_caller], do: send(caller, :release_page)
      assert :ok = Task.await(first_task)
      assert :ok = Task.await(second_task)
    end
  end

  test "a parsed CSS settlement refreshes both policies without dispatching for the fetch target",
       c do
    parent = self()
    source = ~s|@import "tokens.css";a{background:var(--bg,url(fallback.png))}|

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:requested, conn.request_path, self()})

      {type, body} =
        case conn.request_path do
          "/root" ->
            receive do
              :respond -> :ok
            end

            {"text/css", source}

          "/tokens.css" ->
            receive do
              :respond -> :ok
            end

            {"text/css", ":root{--bg:url(shown.png)}"}

          "/shown.png" ->
            {"image/png", "shown"}
        end

      conn |> Plug.Conn.put_resp_content_type(type) |> Plug.Conn.resp(200, body)
    end)

    opts =
      Map.merge(c.opts, %{
        html_tag: "link",
        mode: :stylesheet,
        assets: ["css", "images"],
        max_body: Options.assign_defaults(%{}).max_body
      })

    direct_task = start_call(:fetch, opts)
    assert_receive {:requested, "/root", responder}, 2_000
    parsed_task = start_call(:parse, opts)
    wait(fn -> assert length(root_jobs(opts)) == 2 end)
    send(responder, :respond)
    assert_receive {:parser_called, url, parser, parsed_target}, 2_000
    assert url == opts.url
    assert_receive {:call_result, :fetch, direct_caller, %Page{} = direct}, 2_000
    before = target_row(direct)
    assert before.version == 1
    refute before.dirty?
    refute_received {:requested, "/tokens.css", _}

    send(parser, {:continue_parser, parsed_target})
    assert_receive {:requested, "/tokens.css", import_responder}, 2_000
    assert_receive {:call_result, :parse, parsed_caller, %Page{} = parsed}, 2_000
    assert_shared_source(direct, parsed, :css, false)
    assert target_row(parsed).version == 1
    send(import_responder, :respond)
    assert_receive {:requested, "/shown.png", _}, 2_000
    ready_export(parsed.opts)
    assert_receive {:parser_called, "https://discovery-policy.test/tokens.css", _, _}
    assert_receive {:parser_called, "https://discovery-policy.test/shown.png", _, _}

    assert target_row(direct).version > before.version
    assert target_row(parsed).version > 1
    refute target_row(direct).dirty?
    refute target_row(parsed).dirty?

    resources = manifest(c)
    roots = Enum.filter(resources, &(&1["url"] == opts.url))
    assert length(roots) == 2
    tokens = Enum.filter(resources, &(&1["url"] == "https://discovery-policy.test/tokens.css"))
    assert tokens != []
    [picture] = Enum.filter(resources, &(&1["url"] == "https://discovery-policy.test/shown.png"))
    outputs = Enum.map(roots, &File.read!(Path.join([c.root, "archive", &1["path"]])))

    assert Enum.count(outputs, &String.contains?(&1, "https://discovery-policy.test/tokens.css")) ==
             1

    assert Enum.count(outputs, fn output ->
             Enum.any?(tokens, &String.contains?(output, Path.basename(&1["path"])))
           end) == 1

    for token <- tokens do
      token_output = File.read!(Path.join([c.root, "archive", token["path"]]))
      assert token_output =~ Path.basename(picture["path"])
    end

    assert_receive {:parser_called, "https://discovery-policy.test/tokens.css", _, _}
    refute_receive {:requested, _, _}
    refute_receive {:parser_called, _, _, _}

    for caller <- [direct_caller, parsed_caller], do: send(caller, :release_page)
    assert :ok = Task.await(direct_task)
    assert :ok = Task.await(parsed_task)
  end

  defp start_call(mode, opts) do
    parent = self()

    Task.async(fn ->
      supplied = Map.put(opts, :discovery_mode, if(mode == :fetch, do: :parse, else: :fetch))
      result = if mode == :fetch, do: Fetcher.fetch(supplied), else: Crawler.crawl_now(supplied)
      send(parent, {:call_result, mode, self(), result})

      case result do
        %Page{} = page ->
          receive do
            :release_page -> Store.release_page(page)
          end

        other ->
          other
      end
    end)
  end

  defp call_timeout(opts) do
    [job | _] = root_jobs(opts)
    {scope, generation, _queue} = job.authority
    assert {:ok, deadline} = Store.run_deadline(scope, generation)
    Crawler.Deadline.remaining(deadline)
  end

  defp root_jobs(opts) do
    Store
    |> :sys.get_state()
    |> Map.fetch!(:scheduler)
    |> Map.fetch!(:frontier)
    |> Map.fetch!(:jobs)
    |> Enum.flat_map(fn {_id, %{job: job}} ->
      if job.logical_key == opts.url and elem(job.authority, 0) === opts.scope,
        do: [job],
        else: []
    end)
  end

  defp assert_shared_source(direct, parsed, kind \\ :html, retained_decode? \\ true) do
    assert direct.source_revision === parsed.source_revision
    assert direct.analysis.lexical_key === parsed.analysis.lexical_key
    assert direct.analysis.revision === parsed.analysis.revision
    assert direct.analysis.allocation.seed === parsed.analysis.allocation.seed
    if retained_decode?, do: assert(direct.analysis.allocation.seed.retained > 0)
    scans = if kind == :html, do: %{html: 1, attribute: 1}, else: %{kind => 1}
    assert direct.analysis.stats.scans == scans
    assert parsed.analysis.stats.scans == scans
    refute MapSet.new(direct.credit.backing) == MapSet.new(parsed.credit.backing)
    receipts = :sys.get_state(Store).resources.receipts

    for ref <- direct.credit.backing ++ parsed.credit.backing do
      assert receipts[ref].actual > 0
      assert map_size(receipts[ref].holders) > 0
    end

    row = :sys.get_state(Store).source_caches[direct.source_revision]
    assert row.decoded.status == :ready
    assert :gb_trees.size(row.cache.slots) == 1
    assert :gb_trees.is_empty(row.cache.waiters)
  end

  defp assert_separate_artifacts(c, direct, parsed) do
    resources = manifest(c)

    roots = Enum.filter(resources, &(&1["url"] == c.opts.url))
    assert length(roots) == 2
    assert length(Enum.uniq_by(roots, & &1["path"])) == 2
    [child] = Enum.filter(resources, &(&1["url"] == "https://discovery-policy.test/child"))
    outputs = Enum.map(roots, &File.read!(Path.join([c.root, "archive", &1["path"]])))

    assert Enum.count(outputs, &String.contains?(&1, "https://discovery-policy.test/child#next")) ==
             1

    assert Enum.count(outputs, &String.contains?(&1, Path.basename(child["path"]) <> "#next")) ==
             1

    jobs = root_jobs(c.opts)
    assert MapSet.new(jobs, & &1.id) == MapSet.new([direct.target_handle, parsed.target_handle])
    state = :sys.get_state(Store)
    assert state.resources.used + state.source_cache_bytes <= c.opts.max_retained_bytes
  end

  defp target_row(page),
    do:
      :sys.get_state(Store).exports[{page.opts.scope, page.opts.generation}].helper.targets[
        page.target_handle
      ]

  defp manifest(c),
    do:
      c.root
      |> Path.join("archive/manifest.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("resources")
end
