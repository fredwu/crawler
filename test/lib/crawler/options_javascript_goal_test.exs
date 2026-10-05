defmodule Crawler.OptionsJavascriptGoalTest do
  use ExUnit.Case, async: false

  alias Crawler.Options

  setup do
    previous = Application.fetch_env(:crawler, :javascript_goal)

    on_exit(fn ->
      case previous do
        {:ok, goal} -> Application.put_env(:crawler, :javascript_goal, goal)
        :error -> Application.delete_env(:crawler, :javascript_goal)
      end
    end)
  end

  test "JavaScript sources default to the module goal without an application setting" do
    Application.delete_env(:crawler, :javascript_goal)
    assert Options.assign_defaults(%{}).javascript_goal == :module
  end

  test "application settings supply either exact JavaScript source goal" do
    for goal <- [:script, :module] do
      Application.put_env(:crawler, :javascript_goal, goal)
      assert Options.assign_defaults(%{}).javascript_goal == goal
    end
  end

  test "caller metadata overrides the application JavaScript goal" do
    for {configured, requested} <- [{:script, :module}, {:module, :script}] do
      Application.put_env(:crawler, :javascript_goal, configured)
      opts = Options.assign_defaults(%{javascript_goal: requested, html_tag: "script"})
      assert opts.javascript_goal == requested
      assert opts.html_tag == "script"
    end
  end
end
