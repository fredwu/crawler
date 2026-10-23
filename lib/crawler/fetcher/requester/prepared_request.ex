defmodule Crawler.Fetcher.Requester.PreparedRequest do
  @moduledoc """
  Internal frozen request snapshot.

  `equivalence` describes the frozen initial request. Response reuse also needs
  the scheduler run keyed by `{scope, generation}` and the response disposition.
  Redirects that consult a live jar require a current Store cookie proof.
  Comparing initial equivalence alone never establishes response reuse.
  Send may bind execution authority without rebuilding the initial request.

  Request authority metadata is limited to scope, generation, queue, execution lease
  and the absolute deadline. Binding a Store cookie proof changes only context
  metadata. Initial URL, body, headers and credentials stay frozen. The context's
  cookie partition records the preparation scope for private auditing; it cannot
  replace the enclosing scheduler run key.

  Cookie limits are one canonical validated policy, frozen for initial and
  redirect response storage. Deferred callbacks cannot select a different policy.

  Control accounting uses trusted execution context. It does not alter frozen
  options or initial equivalence.
  """

  defmodule Equivalence do
    @moduledoc false
    @derive {Inspect, only: []}
    @enforce_keys [:value]
    defstruct [:value]
  end

  defmodule Context do
    @moduledoc false
    @derive {Inspect, only: []}
    @enforce_keys [:allow_redirect, :policy, :cookie_partition]
    defstruct [
      :allow_redirect,
      :policy,
      :cookie_partition,
      :cookie_proof,
      cookie_limits: %{},
      opaque?: false
    ]
  end

  defmodule ReuseDisposition do
    @moduledoc false
    @derive {Inspect, only: []}
    @enforce_keys [:dependency, :disposition]
    defstruct [:dependency, :disposition, :reason]
  end

  @derive {Inspect, only: []}
  @enforce_keys [:request, :equivalence, :context]
  defstruct [:request, :equivalence, :context]
end
