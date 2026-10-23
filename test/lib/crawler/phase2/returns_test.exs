defmodule Crawler.Store.ReturnsTest do
  use ExUnit.Case, async: false

  alias Crawler.Store
  alias Crawler.Store.Execution
  alias Crawler.Store.Page

  defmodule CopiedErrorParser do
    def parse(%Page{} = page), do: {:error, {:copied_body, :binary.copy(page.body)}}
    def parse(other), do: other
  end

  defmodule CopiedErrorStore do
    def add_page_data(_key, body, _opts), do: {:error, {:copied_body, :binary.copy(body)}}
  end

  defmodule NativeClause do
    def call(:allowed), do: :ok
  end

  test "native function clause returns preserve MFA and location without copying stack arguments" do
    scope = make_ref()
    on_exit(fn -> Store.dispose_scope(scope) end)

    try do
      Execution.run(%{scope: scope, prepared_request: :return_test}, fn _opts ->
        NativeClause.call(%{callback: fn -> :private_argument end})
      end)

      flunk("expected the original function clause error")
    catch
      :error, :function_clause ->
        assert [{NativeClause, :call, 1, location} | _] = __STACKTRACE__
        assert is_list(location[:file])
        assert is_integer(location[:line])
    end
  end

  test "private parser and storage errors retain independent custody until each caller exits" do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
    name = {__MODULE__, make_ref()}
    body = :binary.copy("p", 65_536)

    Req.Test.stub(name, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.put_resp_header("cache-control", "private, no-store")
      |> Plug.Conn.send_resp(200, body)
    end)

    owner = self()

    for {parser, storage} <- [{CopiedErrorParser, nil}, {Crawler.Parser, CopiedErrorStore}] do
      scope = make_ref()

      caller =
        spawn(fn ->
          results =
            for index <- 1..3 do
              Crawler.crawl_now(%{
                scope: scope,
                url: "https://return.test/private-#{index}",
                store: storage,
                parser: parser,
                retries: 0,
                respect_robots: false,
                max_body: 1_048_576,
                max_analysis_bytes: 1_048_576,
                req_options: [plug: {Req.Test, name}]
              })
            end

          Process.put(:held_errors, results)
          send(owner, {:held_errors, self(), Enum.map(results, &error_size/1)})

          receive do
            :finish -> :ok
          end
        end)

      on_exit(fn ->
        Process.exit(caller, :kill)
        Store.dispose_scope(scope)
      end)

      assert_receive {:held_errors, ^caller, [65_536, 65_536, 65_536]}, 5_000
      state = :sys.get_state(Store)
      records = for {_token, %{caller: ^caller} = record} <- state.execution_returns, do: record
      assert length(records) == 3

      for record <- records do
        assert record.state == :accepted
        assert [backing] = record.refs
        assert state.resources.receipts[backing].actual >= 65_536
        assert state.resources.receipts[backing].holders[caller].status == :retained
        assert state.resources.receipts[record.copy].kind == :return_copy
        assert state.resources.receipts[record.copy].actual >= 1_024
      end

      targets =
        for {_id, %{job: %{authority: {^scope, _, _}}, outcome: outcome}} <-
              state.scheduler.frontier.jobs,
            not is_nil(outcome),
            do: outcome

      assert length(targets) == 3

      for outcome <- targets do
        assert outcome.status == :failed
        assert {:opaque_failure, nonce} = outcome.reason
        assert is_reference(nonce)
        assert :erlang.external_size(outcome) < 1_024
      end

      assert Crawler.Store.Resources.bytes(state.resources) <= state.resources.limit
      monitor = Process.monitor(caller)
      send(caller, :finish)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}

      await(fn ->
        current = :sys.get_state(Store)
        refute Map.has_key?(current.return_callers, caller)

        for record <- records, ref <- [record.copy | record.refs] do
          refute current.resources.receipts[ref]
        end
      end)

      Store.dispose_scope(scope)
    end
  end

  test "raw return limits include physical backing and reject functions before environment copying" do
    large = :binary.copy("x", 524_288)

    for result <- [
          {:error, large},
          {:error, fn -> large end}
        ] do
      scope = make_ref()
      on_exit(fn -> Store.dispose_scope(scope) end)

      assert {:error, {:limit, :max_retained_bytes}} =
               Execution.run(
                 %{
                   scope: scope,
                   prepared_request: :return_test,
                   max_body: 0,
                   max_analysis_bytes: 500_000
                 },
                 fn _opts -> result end
               )
    end

    await(fn -> assert :sys.get_state(Store).execution_returns == %{} end)
  end

  test "funded throws errors and exits preserve their original class and payload" do
    owner = self()

    for kind <- [:throw, :error, :exit] do
      scope = make_ref()

      caller =
        spawn(fn ->
          result =
            try do
              Execution.run(
                %{
                  scope: scope,
                  prepared_request: :return_test,
                  max_body: 0,
                  max_analysis_bytes: 1_048_576
                },
                fn _opts ->
                  :erlang.raise(kind, {:private_failure, :binary.copy("e", 65_536)}, [])
                end
              )
            catch
              caught, {:private_failure, body} ->
                Process.put(:held_exception, {caught, body, __STACKTRACE__})
                {caught, byte_size(body), __STACKTRACE__}
            end

          send(owner, {:raised_return, self(), result})

          receive do
            :finish -> :ok
          end
        end)

      on_exit(fn ->
        Process.exit(caller, :kill)
        Store.dispose_scope(scope)
      end)

      assert_receive {:raised_return, ^caller, {^kind, 65_536, []}}, 5_000
      state = :sys.get_state(Store)

      assert [{_token, record}] =
               Enum.filter(state.execution_returns, fn {_token, record} ->
                 record.caller == caller
               end)

      assert record.state == :accepted
      assert [backing] = record.refs
      assert state.resources.receipts[backing].actual >= 65_536
      monitor = Process.monitor(caller)
      send(caller, :finish)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
      await(fn -> refute Map.has_key?(:sys.get_state(Store).return_callers, caller) end)
    end
  end

  test "outcome projections keep typed limits and fixed callback classes without payloads" do
    alias Crawler.Job.Outcome
    secret = :binary.copy("s", 65_536)
    first = Outcome.from_result({:error, secret})
    second = Outcome.from_result({:error, secret})
    assert first != second
    assert first == Outcome.bounded(first)

    projected =
      Outcome.bounded(%Outcome{
        status: :failed,
        reason: secret,
        representation_id: secret,
        interpretation_id: fn -> secret end
      })

    assert projected.representation_id == nil
    assert projected.interpretation_id == nil
    assert :erlang.external_size(projected) < 1_024
    assert Outcome.from_result({:error, {:throw, secret}}).reason == {:callback, :throw}

    for reason <- [
          {:executor_down, :killed},
          {:snapshot, :cleanup_failed},
          {:request_preparation, :invalid_options}
        ] do
      assert Outcome.from_result({:error, reason}).reason == reason
    end

    assert Outcome.from_result({:error, {:executor_down, secret}}).reason == :executor_down
    assert Outcome.from_result({:error, {:deadline, :attempt}}).status == :limited

    assert Outcome.from_result({:error, {:limit, {:cached_analysis, :max_facts}}}).reason ==
             {:limit, {:cached_analysis, :max_facts}}
  end

  defp error_size({:error, {:copied_body, body}}), do: byte_size(body)
  defp error_size(other), do: other

  defmodule ChangedOutput do
    def parse(%Page{} = page) do
      %{
        page
        | body: :binary.copy("b", 65_536),
          opts: Map.put(page.opts, :callback_binary, :binary.copy("c", 65_536))
      }
    end

    def parse(other), do: other
  end

  test "a custom parser's new body and option backing receive separate prepaid custody" do
    scope = make_ref()
    on_exit(fn -> Store.dispose_scope(scope) end)
    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.send_resp(200, "original")
    end)

    opts =
      Crawler.Options.assign_defaults(%{
        scope: scope,
        url: "https://return.test/changed",
        store: nil,
        respect_robots: false,
        parser: ChangedOutput,
        req_options: [plug: {Req.Test, name}]
      })

    assert %Page{body: body, credit: %{return_token: token}} = page = Crawler.crawl_now(opts)
    assert byte_size(body) == 65_536
    assert byte_size(page.opts.callback_binary) == 65_536
    state = :sys.get_state(Store)
    assert state.resources.receipts[state.execution_returns[token].copy].actual >= 131_072
    assert :ok = Store.release_page(page)
  end

  defmodule ChangedCredit do
    def parse(%Page{} = page) do
      %{page | credit: %{page.credit | backing: nil}}
    end

    def parse(other), do: other
  end

  test "callback credit changes cannot drop the canonical backing holder" do
    scope = make_ref()
    on_exit(fn -> Store.dispose_scope(scope) end)
    name = {__MODULE__, make_ref()}
    body = :binary.copy("a", 65_536)

    Req.Test.stub(name, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.send_resp(200, body)
    end)

    opts =
      Crawler.Options.assign_defaults(%{
        scope: scope,
        url: "https://return.test/credit",
        store: nil,
        respect_robots: false,
        parser: ChangedCredit,
        req_options: [plug: {Req.Test, name}]
      })

    assert %Page{credit: %{backing: [backing]}} = page = Crawler.crawl_now(opts)
    assert :sys.get_state(Store).resources.receipts[backing]
    assert :ok = Store.release_page(page)
  end

  test "backing proof uses physical identity and bounds native iterator continuations" do
    original = :binary.copy("a", 65_536)
    replacement = :binary.copy(original)
    assert original == replacement
    refute :erts_debug.same(original, replacement)

    assert {:ok, bytes} =
             Crawler.Store.Retained.return_bytes(%{body: original}, %{body: original}, 4_096)

    assert bytes < 4_096

    assert {:error, {:limit, :max_retained_bytes}} =
             Crawler.Store.Retained.return_bytes(%{body: replacement}, %{body: original}, 4_096)

    base = Map.new(1..33, &{&1, 0})
    {first, _, _} = :maps.next(:maps.iterator(base))
    tree = Enum.reduce(1..128, 0, fn _, child -> Map.put(base, first, child) end)

    assert {:error, {:limit, :max_retained_bytes}} =
             Crawler.Store.Retained.copy_bytes(tree, 67_108_864)
  end

  test "a structural Page copy is rejected before send when its arena has no overlap credit" do
    parent = self()
    scope = make_ref()
    on_exit(fn -> Store.dispose_scope(scope) end)

    result =
      Execution.run(
        %{scope: scope, prepared_request: :return_test, max_body: 0, max_analysis_bytes: 500_000},
        fn opts ->
          assert {:ok, receipt} = Store.reserve_resource(opts, :analysis, 150_000)
          assert :ok = Store.commit_resource(receipt, 150_000)
          send(parent, {:structural_receipt, receipt})

          %Page{
            body: <<>>,
            opts: opts,
            analysis: Map.new(1..1_000, &{&1, {&1, [&1, &1]}}),
            credit: %{retained: [receipt], backing: [], reservation: opts.return_reservation}
          }
        end
      )

    assert result == {:error, {:limit, :max_retained_bytes}}
    assert_receive {:structural_receipt, receipt}

    await(fn ->
      refute :sys.get_state(Store).resources.receipts[receipt]
      assert :sys.get_state(Store).execution_returns == %{}
    end)
  end

  test "amplified Analysis aliases cannot send unfunded structural Pages to held callers" do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
    attrs = Enum.map_join(1..2_000, " ", &"data-#{&1}='x'")

    body =
      "<a href='/next' src='' srcset='' imagesrcset='' content='' data='' poster='' background='' " <>
        attrs <> ">x</a>"

    options =
      Crawler.Options.assign_defaults(%{
        url: "https://return.test/",
        content_type: "text/html",
        html_tag: "a",
        respect_robots: false,
        assets: []
      })

    analysis_opts = Map.merge(options, Map.new(Crawler.Limits.analysis(options)))
    assert {:ok, analysis} = Crawler.Analysis.analyze(body, analysis_opts)
    assert {:ok, groups} = Crawler.Analysis.css_groups_result(analysis, options)
    assert {:ok, prepared} = Crawler.Parser.prepare_collection(analysis, options, %{}, groups)
    assert map_size(analysis.regions) == 9
    assert prepared.collection.budget.retained < 2_000_000

    assert {:error, {:limit, :max_retained_bytes}} =
             Crawler.Store.Retained.copy_bytes(
               %Page{
                 body: body,
                 analysis: analysis,
                 interpretation: prepared,
                 opts: prepared.opts
               },
               options.max_retained_bytes
             )

    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, body)
    end)

    parent = self()

    actors =
      for index <- 1..7 do
        scope = make_ref()

        caller =
          spawn(fn ->
            result =
              Crawler.Fetcher.fetch(
                Map.merge(options, %{
                  scope: scope,
                  store: nil,
                  url: "https://return.test/page-#{index}",
                  req_options: [plug: {Req.Test, name}]
                })
              )

            if match?(%Page{}, result), do: Process.put(:held_page, result)

            send(
              parent,
              {:amplified_return, index, if(match?(%Page{}, result), do: :page, else: result)}
            )

            receive do
              :release -> :ok
            end
          end)

        on_exit(fn ->
          Process.exit(caller, :kill)
          Store.dispose_scope(scope)
        end)

        assert_receive {:amplified_return, ^index, {:error, {:limit, :max_retained_bytes}}}, 5_000

        assert Crawler.Store.Resources.bytes(:sys.get_state(Store).resources) <=
                 options.max_retained_bytes

        {caller, scope}
      end

    assert :sys.get_state(Store).execution_returns == %{}

    for {caller, scope} <- actors do
      send(caller, :release)
      Store.dispose_scope(scope)
    end
  end

  test "an accepted Page stays charged after its producer and run end" do
    scope = make_ref()
    on_exit(fn -> Store.dispose_scope(scope) end)
    page = Execution.run(%{scope: scope, prepared_request: :return_test}, &page/1)
    assert %Page{credit: %{return_token: token, retained: [receipt]}} = page
    record = :sys.get_state(Store).execution_returns[token]
    assert record.state == :accepted
    copy = :sys.get_state(Store).resources.receipts[record.copy]
    assert copy.actual >= :erts_debug.flat_size(page) * :erlang.system_info(:wordsize)
    Store.dispose_scope(scope)
    await(fn -> assert :sys.get_state(Store).executions == %{} end)
    assert :sys.get_state(Store).resources.receipts[receipt].holders[self()].status == :retained
    assert :ok = Store.release_page(page)
    await(fn -> refute :sys.get_state(Store).resources.receipts[receipt] end)
    refute :sys.get_state(Store).resources.receipts[record.copy]
    refute :sys.get_state(Store).execution_returns[token]
  end

  test "an expired suspended caller releases its queued Page only after result discard" do
    parent = self()
    scope = make_ref()
    on_exit(fn -> Store.dispose_scope(scope) end)

    caller =
      spawn(fn ->
        result =
          Execution.run(
            %{scope: scope, prepared_request: :return_test, attempt_timeout: 200},
            fn opts ->
              result = page(opts)
              send(parent, {:return_executor, self(), result.credit.retained})

              receive do
                :deliver -> result
              end
            end
          )

        send(parent, {:returned, result, Process.info(self(), :messages)})
      end)

    assert_receive {:return_executor, executor, [receipt]}
    assert :erlang.suspend_process(caller)

    try do
      send(executor, :deliver)

      await(fn ->
        assert {:messages, [_ | _]} = Process.info(caller, :messages)
        refute Process.alive?(executor)
      end)

      Store.dispose_scope(scope)
      assert :sys.get_state(Store).resources.receipts[receipt].holders[caller]
      Process.sleep(220)
      assert :sys.get_state(Store).resources.receipts[receipt].holders[caller]
    after
      if Process.alive?(caller), do: :erlang.resume_process(caller)
    end

    assert_receive {:returned, {:error, {:deadline, :attempt}}, {:messages, []}}, 1_000

    await(fn ->
      refute :sys.get_state(Store).resources.receipts[receipt]
      assert :sys.get_state(Store).execution_returns == %{}
    end)
  end

  test "two returned Pages share backing custody until both return tokens are released" do
    scope = make_ref()
    on_exit(fn -> Store.dispose_scope(scope) end)
    caller = self()

    task =
      Task.async(fn ->
        Execution.run(
          %{
            scope: scope,
            prepared_request: :return_test,
            max_body: 65_536,
            max_analysis_bytes: 1_048_576
          },
          fn opts ->
            body = :binary.copy("a", 65_536)
            assert {:ok, receipt} = Store.reserve_resource(opts, :response, 65_600)
            assert :ok = Store.commit_response_resource(receipt, 65_600, 64)

            for _ <- 1..2 do
              assert {:ok, reservation} = Store.reserve_resource(opts, :snapshot, 16_384)

              page = %Page{
                body: body,
                opts: %{},
                credit: %{
                  retained: [],
                  backing: [receipt],
                  reservation: reservation
                }
              }

              assert {:ok, bytes} =
                       Crawler.Store.Retained.return_bytes(page, nil, opts.max_retained_bytes)

              assert {:ok, copy} =
                       Store.reserve_resource(opts, :return_copy, bytes, Process.whereis(Store))

              assert :ok = Store.commit_resource(copy, bytes)

              assert {:ok, token} =
                       Store.prepare_execution_return(
                         opts,
                         caller,
                         Map.put(page.credit, :copy_receipt, copy)
                       )

              send(
                caller,
                {:shared_return, %{page | credit: Map.put(page.credit, :return_token, token)}}
              )
            end

            send(caller, {:shared_producer, self()})

            receive do
              :finish -> :ok
            end
          end
        )
      end)

    assert_receive {:shared_return, %Page{credit: %{backing: [receipt]}} = first}
    assert_receive {:shared_return, %Page{credit: %{backing: [^receipt]}} = second}
    assert_receive {:shared_producer, producer}
    assert :ok = Store.accept_execution_return(first.credit.return_token)
    assert :ok = Store.accept_execution_return(second.credit.return_token)
    send(producer, :finish)
    assert Task.await(task) == :ok
    assert first.credit.return_token != second.credit.return_token
    assert :sys.get_state(Store).return_uses[{self(), receipt}] == 2
    Store.dispose_scope(scope)
    assert :ok = Store.release_page(second)
    assert :sys.get_state(Store).return_uses[{self(), receipt}] == 1
    assert :sys.get_state(Store).resources.receipts[receipt].holders[self()]
    assert :ok = Store.release_page(first)
    await(fn -> refute :sys.get_state(Store).resources.receipts[receipt] end)
  end

  test "return credit permits four retained and four distinct backing grants" do
    scope = make_ref()
    on_exit(fn -> Store.dispose_scope(scope) end)

    assert %Page{} =
             page =
             Execution.run(
               %{
                 scope: scope,
                 prepared_request: :return_test,
                 max_body: 0,
                 max_analysis_bytes: 1_048_576
               },
               fn opts ->
                 retained = Enum.map(1..4, fn _ -> return_grant(opts, :analysis) end)
                 backing = Enum.map(1..4, fn _ -> return_grant(opts, :response) end)

                 %Page{
                   body: "",
                   opts: opts,
                   credit: %{
                     retained: retained,
                     backing: backing,
                     reservation: opts.return_reservation
                   }
                 }
               end
             )

    assert length(page.credit.retained) == 4
    assert length(page.credit.backing) == 4
    state = :sys.get_state(Store)
    assert length(state.execution_returns[page.credit.return_token].refs) == 8
    assert :ok = Store.release_page(page)
  end

  test "return role ceilings and cross-role duplicate checks remain independent" do
    for variant <- [:retained_overflow, :backing_overflow, :duplicate] do
      scope = make_ref()
      on_exit(fn -> Store.dispose_scope(scope) end)

      assert {:error, :invalid_return_credit} =
               Execution.run(
                 %{
                   scope: scope,
                   prepared_request: :return_test,
                   max_body: 0,
                   max_analysis_bytes: 1_048_576
                 },
                 fn opts ->
                   retained = Enum.map(1..5, fn _ -> return_grant(opts, :analysis) end)
                   backing = Enum.map(1..5, fn _ -> return_grant(opts, :response) end)

                   {retained, backing} =
                     case variant do
                       :retained_overflow -> {retained, Enum.take(backing, 1)}
                       :backing_overflow -> {Enum.take(retained, 1), backing}
                       :duplicate -> {[hd(retained)], [hd(retained)]}
                     end

                   %Page{
                     body: "",
                     opts: opts,
                     credit: %{
                       retained: retained,
                       backing: backing,
                       reservation: opts.return_reservation
                     }
                   }
                 end
               )

      assert Process.alive?(Process.whereis(Store))
    end
  end

  defp return_grant(opts, kind) do
    assert {:ok, receipt} = Store.reserve_resource(opts, kind, 64)

    result =
      if kind == :response,
        do: Store.commit_response_resource(receipt, 64, 64),
        else: Store.commit_resource(receipt, 64)

    assert :ok = result
    receipt
  end

  defp page(opts) do
    assert {:ok, receipt} = Store.reserve_resource(opts, :analysis, 1_024)
    assert :ok = Store.commit_resource(receipt, 1_024)

    %Page{
      body: :binary.copy("a", 1_024),
      opts: opts,
      credit: %{retained: [receipt], backing: [], reservation: opts.return_reservation}
    }
  end

  defp await(check, attempts \\ 200)
  defp await(check, 0), do: check.()

  defp await(check, attempts) do
    try do
      check.()
    rescue
      ExUnit.AssertionError ->
        Process.sleep(5)
        await(check, attempts - 1)
    end
  end
end
