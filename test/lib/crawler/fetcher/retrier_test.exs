defmodule Crawler.Fetcher.RetrierTest do
  use Crawler.TestCase, async: true

  alias Crawler.Fetcher.Retrier

  doctest Retrier

  test "retries an error tuple the requested number of extra times" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    result =
      Retrier.perform(
        fn ->
          count = Agent.get_and_update(attempts, fn n -> {n + 1, n + 1} end)
          if count < 3, do: {:error, :down}, else: :ok
        end,
        %{retries: 2, timeout: 20}
      )

    assert result == :ok
    assert Agent.get(attempts, & &1) == 3
  end

  test "does not retry a warning" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    result =
      Retrier.perform(
        fn ->
          Agent.update(attempts, &(&1 + 1))
          {:warn, "skip"}
        end,
        %{retries: 3, timeout: 20}
      )

    assert result == {:warn, "skip"}
    assert Agent.get(attempts, & &1) == 1
  end

  test "an exhausted retry keeps the final tagged error" do
    attempts = :counters.new(1, [:atomics])

    assert {:error, :down} =
             Retrier.perform(
               fn ->
                 :counters.add(attempts, 1, 1)
                 {:error, :down}
               end,
               %{retries: 2}
             )

    assert :counters.get(attempts, 1) == 3
  end

  test "limits, deadlines and revoked authority preserve the first result without retry" do
    for reason <- [
          {:limit, :max_retained_bytes},
          {:deadline, :attempt},
          {:deadline, :run},
          :stale,
          :cancelled,
          :closed_export,
          :representation_deferred,
          :control_prepared
        ] do
      attempts = :counters.new(1, [:atomics])

      assert Retrier.perform(
               fn ->
                 :counters.add(attempts, 1, 1)
                 if :counters.get(attempts, 1) == 1, do: {:error, reason}, else: :ok
               end,
               %{retries: 2}
             ) == {:error, reason}

      assert :counters.get(attempts, 1) == 1
    end
  end

  test "a callback exception propagates immediately without consuming retry attempts" do
    attempts = :counters.new(1, [:atomics])

    assert_raise RuntimeError, "callback failed", fn ->
      Retrier.perform(
        fn ->
          :counters.add(attempts, 1, 1)
          raise "callback failed"
        end,
        %{retries: 3}
      )
    end

    assert :counters.get(attempts, 1) == 1
  end
end
