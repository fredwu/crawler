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
end
