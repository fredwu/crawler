defmodule Crawler.OptionsTest do
  use Crawler.TestCase, async: false

  alias Crawler.Options
  alias Crawler.Store

  doctest Options

  setup do
    original = Application.fetch_env(:crawler, :scope)
    ambient = unique_scope("options-default-scope")
    Application.put_env(:crawler, :scope, ambient)

    on_exit(fn ->
      case original do
        {:ok, scope} -> Application.put_env(:crawler, :scope, scope)
        :error -> Application.delete_env(:crawler, :scope)
      end
    end)

    %{ambient: ambient}
  end

  for scope <- [nil, :bound_options_scope] do
    test "defaults preserve the #{inspect(scope)} identity of a supplied capability" do
      scope = unquote(scope)
      generation = Store.generation(scope)
      on_exit(fn -> Store.dispose_scope(scope) end)
      opts = Options.assign_defaults(%{generation: generation})
      assert opts.scope === scope
      assert Options.assign_scope(opts).scope === scope
      assert Options.assign_scope(%{generation: generation}).scope === scope
      Store.drop_scope(scope)
      assert Options.assign_scope(opts).generation === generation
      refute Store.current?(scope, generation)
    end
  end

  test "explicit scope overrides a capability and application default" do
    generation = Store.generation(nil)
    on_exit(fn -> Store.dispose_scope(nil) end)
    opts = Options.assign_defaults(%{scope: :explicit_options_scope, generation: generation})
    assert Options.assign_scope(opts).scope == :explicit_options_scope
    assert Options.assign_scope(opts).generation === generation
  end

  test "unbound defaults use application scope while explicit nil starts a new scope", context do
    assert Options.assign_scope(Options.assign_defaults(%{})).scope == context.ambient
    assert Options.assign_scope(%{}).scope == context.ambient
    assert is_integer(Options.assign_scope(%{scope: nil}).scope)
    assert is_integer(Options.assign_scope(Options.assign_defaults(%{scope: nil})).scope)
  end
end
