defmodule Crawler.Phase2.PipelineIntegrationTest do
  use ExUnit.Case, async: false

  alias Crawler.Store
  alias Crawler.Store.Resources

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
    :ok
  end

  defmodule Parser do
    def parse(page) do
      prepared = page.interpretation

      result =
        Crawler.Analysis.render_with_stats(
          prepared.analysis,
          prepared.collection,
          &Crawler.Analysis.online_fallback/1
        )

      {:ok, rendered, stats} = result
      state = :sys.get_state(Store)
      lease = page.opts.execution_lease
      execution = state.executions[lease]
      arena = state.resources.arenas[execution.arena]
      source = state.scheduler.representations[page.opts.representation_id].source
      backing = state.resources.receipts[page.opts.body_resource]

      for {receipt, body} <-
            Enum.uniq_by(
              [
                {source.receipt, source.value.body},
                {page.opts.body_resource, page.body}
              ],
              &elem(&1, 0)
            ) do
        :ok = Store.retain_resource(receipt, page.opts.pipeline_holder)
        {:ok, _} = Store.deliver_resource(receipt, page.opts.pipeline_holder, {:backing, body})
      end

      send(page.opts.pipeline_observer, {
        :pipeline,
        self(),
        %{
          rendered_bytes: byte_size(rendered),
          raw_bytes: byte_size(source.value.body),
          decoded_bytes: byte_size(page.body),
          raw_same?: :erts_debug.same(source.value.body, page.body),
          decoded_same?: :erts_debug.same(prepared.source, page.body),
          body_receipt: page.opts.body_resource,
          raw_receipt: source.receipt,
          backing_bytes: backing.actual,
          budget: stats.budget,
          arena: execution.arena,
          envelope: Crawler.Store.ResourceManager.envelope(page.opts),
          used: Resources.bytes(state.resources),
          arena_free: arena.free
        }
      })

      receive do
        :release_pipeline -> {:ok, page}
      end
    end
  end

  for encoding <- [:utf8, :utf8_bom, :utf16] do
    test "managed #{encoding} roots, occurrences and render share one funded pipeline" do
      scope = make_ref()
      parent = self()
      holder = spawn(fn -> hold_backing(parent, []) end)
      on_exit(fn -> Process.exit(holder, :kill) end)
      on_exit(fn -> Store.dispose_scope(scope) end)

      source =
        "<html><body>" <> :binary.copy("界", 50_000) <> "<a href='/next'>x</a></body></html>"

      {wire, type} =
        case unquote(encoding) do
          :utf8 ->
            {source, "text/html; charset=utf-8"}

          :utf8_bom ->
            {<<0xEF, 0xBB, 0xBF>> <> source, "text/html; charset=utf-8"}

          :utf16 ->
            {<<0xFF, 0xFE>> <> :unicode.characters_to_binary(source, :utf8, {:utf16, :little}),
             "text/html"}
        end

      name = {__MODULE__, make_ref()}

      Req.Test.stub(name, fn conn ->
        conn |> Plug.Conn.put_resp_header("content-type", type) |> Plug.Conn.send_resp(200, wire)
      end)

      opts = [
        scope: scope,
        parser: Parser,
        pipeline_observer: self(),
        pipeline_holder: holder,
        store: Store,
        respect_robots: false,
        retries: 0,
        max_body: max(byte_size(wire), byte_size(source)),
        max_analysis_bytes: 2_000_000,
        attempt_timeout: 5_000,
        req_options: [plug: {Req.Test, name}]
      ]

      assert {:ok, admitted} = Crawler.crawl("https://pipeline.test/index", opts)
      on_exit(fn -> Crawler.stop(admitted) end)
      assert_receive {:pipeline, executor, observation}, 2_000
      assert observation.decoded_bytes == byte_size(source)
      assert observation.rendered_bytes >= byte_size(source)
      assert observation.decoded_same?
      assert observation.budget.scratch == 0
      assert observation.budget.peak <= 2_000_000

      assert observation.envelope ==
               max(2 * admitted.max_body, admitted.max_body + 2_000_000) + 65_536

      assert observation.used <= admitted.max_retained_bytes
      assert observation.arena_free >= 0

      if unquote(encoding) in [:utf8, :utf8_bom] do
        assert observation.raw_bytes ==
                 observation.decoded_bytes +
                   if(unquote(encoding) == :utf8_bom, do: 3, else: 0)

        assert observation.body_receipt == observation.raw_receipt
      else
        refute observation.raw_same?
        assert observation.body_receipt != observation.raw_receipt
        assert observation.backing_bytes >= byte_size(source) + 64
      end

      for receipt <- Enum.uniq([observation.raw_receipt, observation.body_receipt]) do
        assert_receive {:backing_held, ^receipt}, 1_000
      end

      assert :ok = Store.dispose_scope(scope)

      await(fn ->
        state = :sys.get_state(Store)
        assert state.resources.receipts[observation.raw_receipt]
        assert state.resources.receipts[observation.body_receipt]
      end)

      await(fn -> refute Process.alive?(executor) end)
      send(holder, :drop)

      await(fn ->
        state = :sys.get_state(Store)
        refute state.resources.receipts[observation.raw_receipt]
        refute state.resources.receipts[observation.body_receipt]
        refute state.resources.arenas[observation.arena]
      end)
    end
  end

  defp hold_backing(parent, backings) do
    receive do
      {:crawler_resource_delivery, receipt, _lease, _reply, _ref, {:backing, body}} ->
        send(Store, {:crawler_resource_adopted, receipt, self()})
        _ = :sys.get_state(Store)
        send(parent, {:backing_held, receipt})
        hold_backing(parent, [body | backings])

      :drop ->
        Enum.each(backings, &byte_size/1)
        :ok
    end
  end

  defp await(check, attempts \\ 300)

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
