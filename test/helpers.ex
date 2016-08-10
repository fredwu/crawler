# Credit: https://gist.github.com/cblavier/5e15791387a6e22b98d8
defmodule Helpers do
  def wait(fun), do: wait(500, fun)
  def wait(0, fun), do: fun.()
  def wait(timeout, fun) do
    try do
      fun.()
    rescue
      _ ->
        :timer.sleep(10)
        wait(max(0, timeout - 10), fun)
    end
  end
end
