defmodule Crawler.Fetcher.SourceCacheConsumerTest do
  use ExUnit.Case, async: false
  alias Crawler.Analysis
  alias Crawler.Charset
  alias Crawler.Fetcher
  alias Crawler.Store
  alias Crawler.Store.Execution
  alias Crawler.Store.Page

  setup do
    scope = make_ref()
    on_exit(fn -> Store.dispose_scope(scope) end)
    %{scope: scope}
  end

  test "compatible interpretations reuse physical bytes, decode and lexical facts", c do
    opts = server(c, "text/html", "<p>same</p>")
    trace_source()

    pages =
      for group <- [:first, :second, :third],
          do: Fetcher.fetch(Map.put(opts, :style_group, group))

    assert [%Page{} = first, %Page{} = second, %Page{} = third] = pages
    assert first.source_revision === second.source_revision
    assert second.source_revision === third.source_revision
    assert first.analysis.allocation.seed === second.analysis.allocation.seed
    assert second.analysis.allocation.seed === third.analysis.allocation.seed
    assert calls() == %{decode: 1, lexical: 1}
    assert_receive {:physical_request, "/source"}
    refute_receive {:physical_request, _}
  end

  test "incompatible script goals share only the valid UTF16 decoded root", c do
    source = "const café = 1;"
    opts = server(c, "text/javascript", utf16(source))
    trace_source()

    assert %Page{body: ^source, analysis: script} =
             Fetcher.fetch(Map.put(opts, :javascript_goal, :script))

    assert %Page{body: ^source, analysis: module} =
             Fetcher.fetch(Map.put(opts, :javascript_goal, :module))

    assert script.mode == {:javascript, :script}
    assert module.mode == {:javascript, :module}
    assert script.allocation.seed.retained > 0
    assert module.allocation.seed.retained >= script.allocation.seed.retained
    assert calls() == %{decode: 1, lexical: 2}
  end

  test "a larger frontier ceiling preserves a small decoded and lexical cache hit", c do
    opts = Map.put(server(c, "text/html", "<p>bounded</p>"), :max_frontier_bytes, 134_217_728)
    trace_source()

    assert %Page{body: "<p>bounded</p>"} = Fetcher.fetch(Map.put(opts, :style_group, :first))
    assert %Page{body: "<p>bounded</p>"} = Fetcher.fetch(Map.put(opts, :style_group, :second))
    assert calls() == %{decode: 1, lexical: 1}
    assert_receive {:physical_request, "/source"}
    refute_receive {:physical_request, _}
  end

  for store <- [nil, Store] do
    test "opaque-first UTF16 SVG preserves bytes with store #{inspect(store)}", c do
      source = ~s|<?xml version="1.0" encoding="UTF-16"?><svg><title>café</title></svg>|
      expected = String.replace(source, "UTF-16", "utf-8")
      opts = Map.put(server(c, "image/svg+xml", utf16(source)), :store, unquote(store))
      trace_source()

      assert %Page{body: ^expected, analysis: nil, interpretation: prepared} =
               Fetcher.fetch(Map.merge(opts, %{html_tag: "img", style_group: :picture}))

      assert prepared.analysis == nil
      assert prepared.source == expected

      assert {:ok, ^expected} =
               Crawler.Snapper.LinkReplacer.replace_prepared(
                 prepared,
                 &Analysis.online_fallback/1
               )

      if unquote(store), do: assert(Store.find({opts.url, c.scope}).body == expected)

      assert %Page{body: ^expected, analysis: %Analysis{}} =
               Fetcher.fetch(Map.merge(opts, %{html_tag: "a", style_group: :document}))

      assert calls() == %{decode: 1, lexical: 1}
    end
  end

  test "stricter current limits reject a hit without rescan", c do
    opts = server(c, "text/html", "<p>limits</p>")
    assert %Page{} = Fetcher.fetch(Map.put(opts, :style_group, :original))
    trace_source()

    assert :ok =
             Execution.run_job(Map.put(opts, :style_group, :eleven_limits), fn owned ->
               assert %Page{analysis: analysis} = page = Fetcher.fetch(owned)
               assert map_size(analysis.limits) == 11
               normalized = Map.merge(page.opts, Crawler.Limits.analysis(page.opts))

               for {key, value} <- analysis.limits do
                 assert {:error, {:limit, {:cached_analysis, ^key}}} =
                          Analysis.cached_result(
                            analysis,
                            Map.put(normalized, key, value - 1),
                            analysis.allocation.seed
                          )
               end

               :ok
             end)

    for {key, option} <- [
          max_bytes: :max_body,
          max_total_bytes: :max_analysis_bytes,
          max_regions: :max_analysis_regions,
          max_depth: :max_analysis_depth,
          max_facts: :max_analysis_facts,
          max_occurrences: :max_analysis_occurrences,
          max_edits: :max_analysis_edits,
          max_xml_depth: :max_xml_depth,
          max_xml_tokens: :max_xml_tokens,
          max_xml_attributes: :max_xml_attributes
        ] do
      defaults = Crawler.Options.assign_defaults(opts)
      stricter = opts |> Map.put(:style_group, key) |> Map.put(option, defaults[option] - 1)

      assert {:error, {:limit, {:cached_analysis, rejected}}} =
               Execution.run_job(Map.put(opts, :style_group, key), fn owned ->
                 Fetcher.fetch(Map.put(owned, option, stricter[option]))
               end)

      if option == :max_analysis_bytes do
        assert rejected in [:max_total_bytes, :max_output_bytes]
      else
        assert rejected == key
      end
    end

    assert calls() == %{decode: 0, lexical: 0}
  end

  test "cached history survives while imports have current independent receipts", c do
    opts = server(c, "text/html", utf16("<p>history</p>"))
    first = Fetcher.fetch(Map.put(opts, :style_group, :first))
    history = first.analysis.allocation.seed

    assert %Page{} =
             Execution.run_job(Map.put(opts, :style_group, :second), fn owned ->
               assert %Page{} = page = Fetcher.fetch(owned)
               assert page.analysis.allocation.seed === history
               assert page.analysis.budget.peak >= history.peak
               assert page.credit.unavailable >= history.retained
               assert length(page.credit.retained) == 3
               assert length(page.credit.backing) == 1
               state = :sys.get_state(Store)

               for ref <- page.credit.retained ++ page.credit.backing do
                 assert state.resources.receipts[ref].lease === owned.execution_lease

                 assert state.resources.receipts[ref].holders[self()].lease ===
                          owned.execution_lease
               end

               normalized = Map.merge(page.opts, Crawler.Limits.analysis(page.opts))

               assert {:error, :invalid_budget_continuation} =
                        Analysis.cached_result(
                          page.analysis,
                          normalized,
                          Crawler.Analysis.Budget.new(page.analysis.limits)
                        )

               page
             end)
  end

  test "concurrent opaque and document goals share a single decoded producer", c do
    opts = server(c, "image/svg+xml", utf16("<svg><title>shared</title></svg>"))
    gate_source(:decoded)
    trace_source()

    first =
      Task.async(fn ->
        Fetcher.fetch(Map.merge(opts, %{html_tag: "img", style_group: :opaque}))
      end)

    assert_receive {:held_source, owner, context}, 2_000
    second = Task.async(fn -> Fetcher.fetch(Map.put(opts, :style_group, :document)) end)
    assert_receive {:source_waiter, waiter, waiting}, 2_000
    refute owner == waiter
    assert context.source_revision === waiting.source_revision
    resume_gate(context)
    assert %Page{analysis: nil, body: body} = Task.await(first)
    assert %Page{analysis: %Analysis{}, body: ^body, target_handle: target} = Task.await(second)
    assert target === waiting.target_handle
    assert calls() == %{decode: 1, lexical: 1}
    assert_receive {:physical_request, "/source"}
    refute_receive {:physical_request, _}
  end

  for cell <- [:decoded, :lexical] do
    test "#{cell} producer death retries under the waiter's exact current target", c do
      opts = server(c, "image/svg+xml", utf16("<svg/>"))
      gate_source(unquote(cell))
      trace_source()
      first_opts = if unquote(cell) == :decoded, do: Map.put(opts, :html_tag, "img"), else: opts

      first =
        Task.async(fn ->
          try do
            Fetcher.fetch(Map.put(first_opts, :style_group, :producer))
          catch
            :exit, _ -> :producer_down
          end
        end)

      assert_receive {:held_source, owner, original}, 2_000
      second = Task.async(fn -> Fetcher.fetch(Map.put(opts, :style_group, :waiter)) end)
      assert_receive {:source_waiter, _worker, waiting}, 2_000
      assert waiting.representation_id === original.representation_id
      Process.exit(owner, :kill)
      assert :producer_down = Task.await(first)
      assert %Page{target_handle: target, source_revision: revision} = Task.await(second)
      assert target === waiting.target_handle
      assert revision === waiting.source_revision
      assert calls() == %{decode: 1, lexical: 1}
      assert_receive {:physical_request, "/source"}
      refute_receive {:physical_request, _}
    end
  end

  test "a decoded waiter obeys its own attempt deadline", c do
    opts = server(c, "image/svg+xml", utf16("<svg/>"))
    gate_source(:decoded)

    first =
      Task.async(fn ->
        Fetcher.fetch(Map.merge(opts, %{html_tag: "img", style_group: :producer}))
      end)

    assert_receive {:held_source, _owner, context}, 2_000

    assert {:error, {:deadline, :attempt}} =
             Fetcher.fetch(Map.merge(opts, %{style_group: :waiter, attempt_timeout: 100}))

    resume_gate(context)
    assert %Page{analysis: nil} = Task.await(first)
    eventually(fn -> assert :sys.get_state(Store).source_cache_leases == %{} end)
  end

  test "retirement after committed lexical funding prevents obsolete publication", c do
    opts = server(c, "text/html", "<p>retired</p>")
    gate_source(:publication)
    first = Task.async(fn -> Fetcher.fetch(opts) end)
    assert_receive {:held_source, _owner, context}, 2_000
    Store.drop_scope(c.scope)
    resume_gate(context)
    assert Task.await(first) in [{:warn, :stale}, {:error, :stale}]
    run = {context.scope, context.generation}

    eventually(fn ->
      state = :sys.get_state(Store)
      refute Enum.any?(state.source_caches, fn {_id, record} -> record.run === run end)
      refute Map.has_key?(state.source_cache_leases, context.execution_lease)
    end)
  end

  test "exhausted current funding fails explicitly without an uncached fallback", c do
    opts = server(c, "text/html", "<p>funded</p>")
    assert %Page{} = Fetcher.fetch(Map.put(opts, :style_group, :producer))
    trace_source()

    assert {:error, {:limit, :arena_capacity}} =
             Execution.run_job(Map.put(opts, :style_group, :limited), fn owned ->
               assert {:ok, blocker, _capacity} =
                        Store.reserve_resource_up_to(
                          owned,
                          :scratch,
                          owned.max_analysis_bytes + 2 * owned.max_body
                        )

               try do
                 Fetcher.fetch(owned)
               after
                 Store.release_resource(blocker)
               end
             end)

    assert calls() == %{decode: 0, lexical: 0}
  end

  defmodule Observer do
    def scrape(page) do
      send(page.opts.observer, {:scraped, page.body, page.opts.javascript_goal, page.opts.scope})
      {:ok, page}
    end
  end

  test "direct Fetcher and Parser keep callback bytes after the Document frame ends", c do
    source = "<root><title>callback café</title></root>"

    opts =
      Map.merge(server(c, "application/xml", utf16(source)), %{
        scraper: Observer,
        observer: self()
      })

    for group <- [:first, :second] do
      assert {:ok, %Page{body: ^source, credit: credit} = page} =
               Execution.run_job(Map.put(opts, :style_group, group), fn owned ->
                 assert %Page{} = page = Fetcher.fetch(owned)
                 Crawler.Parser.parse(page)
               end)

      assert length(credit.retained) == 3
      assert length(Enum.uniq(credit.retained)) == 3
      state = :sys.get_state(Store)

      for receipt <- credit.retained ++ credit.backing do
        assert Map.has_key?(state.resources.receipts[receipt].holders, self())
      end

      assert Enum.all?(page.interpretation.analysis.budget.counts, fn {key, count} ->
               page.interpretation.collection.budget.counts[key] >= count
             end)

      assert page.interpretation.collection.budget.peak >=
               page.interpretation.analysis.budget.peak

      assert_receive {:scraped, ^source, :module, scope}
      assert scope === c.scope
      assert :ok = Store.release_page(page)
    end
  end

  defp gate_source(cell) do
    parent = self()
    hook = make_ref()
    store = Process.whereis(Store)

    callback = fn
      :armed, {:in, {:"$gen_call", {worker, _}, request}}, _ ->
        if source_request?(request, cell) do
          context = source_context(request)
          true = :erlang.suspend_process(worker)
          send(parent, {:held_source, worker, context})
          {:held, worker}
        else
          :armed
        end

      {:held, worker}, {:in, {:"$gen_call", {^parent, _}, {:current?, _, _, _}}}, _ ->
        if Process.alive?(worker), do: :erlang.resume_process(worker)
        :done

      {:held, worker} = state, {:in, {:"$gen_call", {other, _}, request}}, _ ->
        if other != worker and source_request?(request, cell),
          do: send(parent, {:source_waiter, other, source_context(request)})

        state

      state, _event, _ ->
        state
    end

    assert :ok = :sys.install(store, {hook, callback, :armed})
    on_exit(fn -> if Process.alive?(store), do: :sys.remove(store, hook) end)
    :ok
  end

  defp source_context({:execution, _, request}), do: source_context(request)
  defp source_context(request), do: elem(request, 1)

  defp source_request?({:execution, _, request}, cell), do: source_request?(request, cell)
  defp source_request?({:source_cache, _, {:acquire_decoded, _, _}}, :decoded), do: true
  defp source_request?({:source_cache, _, {:acquire, _, _, _}}, :lexical), do: true
  defp source_request?({:resource_funding, _, %{retained: [_]}, _}, :publication), do: true
  defp source_request?(_, _), do: false

  defp resume_gate(context),
    do: Store.current?(context.scope, context.generation, context[:queue])

  defp eventually(check, remaining \\ 500)
  defp eventually(check, 0), do: check.()

  defp eventually(check, remaining) do
    try do
      check.()
    rescue
      ExUnit.AssertionError ->
        receive do
        after
          2 -> :ok
        end

        eventually(check, remaining - 1)
    end
  end

  defp utf16(text),
    do: <<255, 254>> <> :unicode.characters_to_binary(text, :utf8, {:utf16, :little})

  defp server(c, type, body) do
    parent = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    pid = spawn(fn -> accept(listener, parent, type, body) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(pid, :kill)
    end)

    %{
      url: "http://127.0.0.1:#{port}/source",
      scope: c.scope,
      store: nil,
      respect_robots: false,
      cookie_navigation: false,
      retries: 0,
      req_options: [retry: false],
      attempt_timeout: 5_000
    }
  end

  defp accept(listener, parent, type, body) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, request} = read_request(socket, "")
        [_, path | _] = String.split(request, " ")
        send(parent, {:physical_request, path})

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: ",
            type,
            "\r\ncontent-length: ",
            Integer.to_string(byte_size(body)),
            "\r\nconnection: close\r\n\r\n",
            body
          ])

        :gen_tcp.close(socket)
        accept(listener, parent, type, body)

      {:error, :closed} ->
        :ok
    end
  end

  defp read_request(socket, bytes) do
    if String.contains?(bytes, "\r\n\r\n") do
      {:ok, bytes}
    else
      with {:ok, next} <- :gen_tcp.recv(socket, 0, 5_000), do: read_request(socket, bytes <> next)
    end
  end

  defp trace_source do
    Code.ensure_loaded!(Charset)
    Code.ensure_loaded!(Crawler.Analysis.Lexical)
    :erlang.trace_pattern({Charset, :decode_owned_result, 3}, true, [:local])
    :erlang.trace_pattern({Crawler.Analysis.Lexical, :run, 4}, true, [:local])
    :erlang.trace(:all, true, [:call, :set_on_spawn, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call, :set_on_spawn])
      :erlang.trace(:new_processes, false, [:call, :set_on_spawn])
      :erlang.trace_pattern({Charset, :decode_owned_result, 3}, false, [:local])
      :erlang.trace_pattern({Crawler.Analysis.Lexical, :run, 4}, false, [:local])
    end)
  end

  defp calls do
    ref = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    after
      2_000 -> flunk("trace barrier timed out")
    end

    collect_calls(%{decode: 0, lexical: 0})
  end

  defp collect_calls(counts) do
    receive do
      {:trace, _pid, :call, {Charset, :decode_owned_result, _}} ->
        collect_calls(Map.update!(counts, :decode, &(&1 + 1)))

      {:trace, _pid, :call, {Crawler.Analysis.Lexical, :run, _}} ->
        collect_calls(Map.update!(counts, :lexical, &(&1 + 1)))
    after
      0 -> counts
    end
  end
end
