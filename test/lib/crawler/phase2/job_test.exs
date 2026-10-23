defmodule Crawler.JobTest do
  use ExUnit.Case, async: true

  alias Crawler.Job

  test "logical resource, representation and interpretation handles remain separate" do
    authority = {:scope, {make_ref(), :scope, make_ref()}, self()}

    attrs = %{
      logical_id: make_ref(),
      representation_id: make_ref(),
      interpretation_id: make_ref()
    }

    job = Job.new(:fetch, authority, attrs)
    assert job.authority == authority
    assert job.logical_id != job.representation_id
    assert job.representation_id != job.interpretation_id
    assert is_reference(job.id)
  end

  test "a copied capability cannot change scope and missing authority is rejected" do
    generation = {make_ref(), :original, make_ref()}
    assert_raise ArgumentError, fn -> Job.new(:fetch, {:other, generation, self()}, %{}) end
    assert_raise ArgumentError, fn -> Job.new(:fetch, {:original, nil, self()}, %{}) end
    assert_raise ArgumentError, fn -> Job.new(:unknown, {:original, generation, self()}, %{}) end
  end

  test "inspection excludes private request and callback options" do
    authority = {:scope, {make_ref(), :scope, make_ref()}, nil}
    job = Job.new(:fetch, authority, %{opts: %{auth: "secret"}, prepared_request: "secret"})
    refute inspect(job) =~ "secret"
    assert Job.Outcome.limited(:max_pending).reason == {:limit, :max_pending}
  end

  test "structured parser and cache limits remain canonical terminal outcomes" do
    for key <- [{:cached_analysis, :max_facts}, {:json, :tokens}, {:css_graph, :work}] do
      expected = %Job.Outcome{status: :limited, reason: {:limit, key}}
      assert Job.Outcome.limited(key) === expected
      assert Job.Outcome.from_result({:error, {:limit, key}}) === expected
      assert Job.Outcome.from_result({:warn, {:limit, key}}) === expected
    end
  end
end
