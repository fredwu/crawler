defmodule Crawler.Job do
  @moduledoc false

  @kinds [:fetch, :interpret, :robots, :sitemap, :css_settlement, :alias_settlement, :finalize]
  @enforce_keys [:id, :kind, :authority]
  @derive {Inspect,
           only: [:id, :kind, :logical_id, :representation_id, :interpretation_id, :control_depth]}
  defstruct [
    :id,
    :kind,
    :authority,
    :logical_id,
    :logical_key,
    :representation_id,
    :interpretation_id,
    :source_revision,
    :prepared_request,
    :deadline,
    opts: %{},
    control_depth: 0
  ]

  def new(kind, {scope, {incarnation, generation_scope, revision}, queue} = authority, attrs)
      when kind in @kinds and scope === generation_scope and is_reference(incarnation) and
             is_reference(revision) and (is_pid(queue) or is_nil(queue)) do
    attrs = Map.new(attrs)

    job =
      struct!(__MODULE__, Map.merge(attrs, %{id: make_ref(), kind: kind, authority: authority}))

    if not is_integer(job.control_depth) or job.control_depth < 0 do
      raise ArgumentError, "job depth must be a non-negative integer"
    end

    job
  end

  def new(_kind, _authority, _attrs),
    do: raise(ArgumentError, "invalid job kind or run authority")

  defmodule Identity do
    @moduledoc false
    @enforce_keys [:representation, :interpretation]
    @derive {Inspect, only: []}
    defstruct [:representation, :interpretation, representation_class: :prepared]
  end

  defmodule Outcome do
    @moduledoc false

    @enforce_keys [:status]
    defstruct [:status, :reason, :representation_id, :interpretation_id]

    def new(status, reason \\ nil)
        when status in [:succeeded, :rejected, :failed, :limited, :cancelled] do
      bounded(%__MODULE__{status: status, reason: reason})
    end

    def bounded(%__MODULE__{status: status} = outcome)
        when status in [:succeeded, :rejected, :failed, :limited, :cancelled] do
      reason = bounded_reason(outcome.reason)

      %__MODULE__{
        status: status,
        reason: reason,
        representation_id: bounded_id(outcome.representation_id),
        interpretation_id: bounded_id(outcome.interpretation_id)
      }
    end

    def bounded(_), do: new(:failed, :invalid_outcome)

    def from_result({:error, {:deadline, kind} = reason}) when kind in [:attempt, :run],
      do: new(:limited, reason)

    def from_result({:error, {:limit, key}}), do: limited(key)
    def from_result({:warn, {:limit, key}}), do: limited(key)
    def from_result({:error, reason}), do: new(:failed, reason)
    def from_result({:warn, reason}), do: new(:rejected, reason)

    def from_result(%Crawler.Store.Page{opts: %{count_page: false}}),
      do: new(:succeeded, :control_document)

    def from_result(%Crawler.Store.Page{}), do: new(:succeeded)
    def from_result({:ok, %Crawler.Store.Page{} = page}), do: from_result(page)
    def from_result({:ok, _}), do: new(:succeeded)
    def from_result(:ok), do: new(:succeeded)
    def from_result(other), do: new(:failed, other)

    def limited(key) when is_atom(key), do: new(:limited, {:limit, key})

    def limited({domain, key}) when is_atom(domain) and is_atom(key),
      do: new(:limited, {:limit, {domain, key}})

    def limited(_), do: new(:failed, :invalid_limit)

    defp bounded_id(id) when is_reference(id), do: id
    defp bounded_id(_), do: nil

    defp bounded_reason(reason) when is_atom(reason), do: reason
    defp bounded_reason({:limit, key} = reason) when is_atom(key), do: reason

    defp bounded_reason({:limit, {domain, key}} = reason)
         when is_atom(domain) and is_atom(key),
         do: reason

    defp bounded_reason({:deadline, kind} = reason) when kind in [:attempt, :run], do: reason

    defp bounded_reason({:callback, kind} = reason) when kind in [:error, :exit, :throw],
      do: reason

    defp bounded_reason({kind, detail} = reason) when is_atom(kind) and is_atom(detail),
      do: reason

    defp bounded_reason({kind, _}) when kind in [:error, :exit, :throw],
      do: {:callback, kind}

    defp bounded_reason({:executor_down, _}), do: :executor_down
    defp bounded_reason({:opaque_failure, nonce} = reason) when is_reference(nonce), do: reason
    defp bounded_reason(_), do: {:opaque_failure, make_ref()}
  end
end
