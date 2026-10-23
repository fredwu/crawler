defmodule Crawler.HTTP do
  import Kernel, except: [send: 2]

  @moduledoc """
  Project-owned HTTP boundary.

  The effective initial request is prepared once. Redirects keep its transport
  settings and rebuild only hop credentials and cookies. The same hostname keeps
  caller headers and authentication across scheme and port changes, including
  HTTPS downgrades. Cookie credential modes still check scheme and port.
  Leaving that hostname permanently removes caller credentials for this chain.
  """

  defmodule RedirectRejected do
    @moduledoc false
    defexception [:url]
    @impl true
    def message(%{url: url}), do: "redirect rejected: #{Crawler.Diagnostics.url(url)}"
  end

  defmodule InvalidURL do
    @moduledoc false
    defexception [:url]
    @impl true
    def message(%{url: url}), do: "invalid HTTP URL: #{Crawler.Diagnostics.url(url)}"
  end

  defmodule StaleExecution do
    @moduledoc false
    defexception message: "request execution is stale"
  end

  defmodule ControlAccountingRejected do
    @moduledoc false
    defexception [:reason]
    @impl true
    def message(_error), do: "control response accounting rejected"
  end

  defmodule CookieStorageRejected do
    @moduledoc false
    @derive {Inspect, only: []}
    defexception [:reason]
    @impl true
    def message(_error), do: "response cookie storage rejected"
  end

  alias Crawler.Cookies
  alias Crawler.Deadline
  alias Crawler.Diagnostics
  alias Crawler.Fetcher.Requester
  alias Crawler.Fetcher.Requester.PreparedRequest
  alias Crawler.Fetcher.Requester.PreparedRequest.ReuseDisposition
  alias Crawler.HTTP.Body
  alias Crawler.HTTP.Transport
  alias Crawler.Store
  alias Crawler.Store.Authority
  alias Crawler.Store.CookieProof.Observation
  alias Crawler.URL

  require Logger

  @safe_redirect_headers ["user-agent", "accept", "accept-language", "accept-encoding"]
  @redirect_statuses [301, 302, 303, 307, 308]
  @options [
    :crawler_scope,
    :crawler_max_body,
    :crawler_user_cookie,
    :crawler_generation,
    :crawler_queue,
    :crawler_execution_lease,
    :crawler_cookie_site,
    :crawler_cookie_navigation,
    :crawler_cookie_credentials,
    :crawler_deadline
  ]
  @authority_options [
    scope: :crawler_scope,
    generation: :crawler_generation,
    queue: :crawler_queue,
    execution_lease: :crawler_execution_lease
  ]
  @request_steps ~w(put_user_agent compressed encode_body put_base_url auth put_params put_path_params put_range cache put_plug compress_body checksum put_aws_sigv4)a
  @response_steps ~w(retry handle_http_errors redirect http_digest decompress_body verify_checksum decode_body output)a
  @control_sequence {__MODULE__, :control_sequence}

  @doc false
  def options, do: @options

  def get(url, headers, opts, allow_redirect \\ fn _url -> true end) do
    case Requester.prepare_http(url, headers, opts, allow_redirect) do
      {:ok, prepared} ->
        Requester.send(prepared)

      {:error, {:request_preparation, :unsupported_follow_redirects}} ->
        Requester.unsupported_redirect!()

      error ->
        error
    end
  end

  @doc false
  def prepare(request, credential_site, context) do
    if Map.has_key?(request.options, :follow_redirects) do
      {:error, {:request_preparation, :unsupported_follow_redirects}}
    else
      opaque? = opaque?(request)

      request =
        request
        |> Req.Request.merge_options(decode_body: false)
        |> Req.Request.put_new_option(:redirect_log_level, false)
        |> Req.Request.put_new_option(:redirect_trusted, true)
        |> Req.Request.put_private(:crawler_into, request.into)
        |> Map.put(:into, &stream/2)
        |> Req.Request.put_new_header("accept-encoding", "gzip, deflate")

      with {:ok, request} <- prepare_steps(request),
           {:ok, url} <- resolve(request.url) do
        opaque? = opaque? or opaque?(request)
        request = freeze_steps(request, url)
        request = Req.Request.put_private(request, :crawler_cookie_limits, context.cookie_limits)
        request = if same_host?(credential_site, url), do: request, else: keep_headers(request)

        request =
          if request.options[:crawler_cookie_site],
            do: request,
            else: Req.Request.put_option(request, :crawler_cookie_site, url)

        user_cookie = cookie_value(request)

        request = Req.Request.merge_options(request, crawler_user_cookie: user_cookie)

        with {:ok, request, observation} <- put_cookie(request, url, :unbound) do
          equivalence = %PreparedRequest.Equivalence{
            value: {
              request.method,
              request.url,
              request.headers,
              request.body,
              request.adapter,
              equivalence_options(request.options),
              request.private,
              request.response_steps,
              request.error_steps,
              {:cookie_jar_partition, :execution_run},
              context.policy,
              if(opaque?, do: make_ref())
            }
          }

          {:ok,
           %PreparedRequest{
             request: pipeline(request),
             equivalence: equivalence,
             context: %{
               context
               | cookie_proof: if(observation, do: observation.proof),
                 opaque?: context.opaque? or opaque?
             }
           }}
        end
      end
    end
  end

  @doc false
  def send(%PreparedRequest{} = prepared, execution_context \\ %{}) do
    context = Map.new(execution_context)
    frozen = prepared.request

    deadline =
      earlier_deadline(
        context[:deadline] || context[:crawler_deadline],
        frozen.options[:crawler_deadline]
      )

    cleanup = {__MODULE__, make_ref()}
    previous_lease = Process.get(:crawler_execution_lease)
    {request, live_context} = bind_execution(frozen, context, deadline)

    request =
      request
      |> Req.Request.put_private(:crawler_allow_redirect, prepared.context.allow_redirect)
      |> Req.Request.put_private(:crawler_execution_context, live_context)
      |> Req.Request.put_private(:crawler_cleanup, cleanup)
      |> Req.Request.put_private(:crawler_cookie_limits, prepared.context.cookie_limits)
      |> Req.Request.put_private(:crawler_cookie_trace, %{
        proof: prepared.context.cookie_proof || :unbound,
        reason: nil,
        dependent?: false,
        opaque?: prepared.context.opaque?
      })

    put_execution_lease(live_context.execution_lease)

    try do
      with :ok <- check_execution(request),
           {:ok, request} <- validate_cookie_proof(request) do
        request |> Req.Request.run_request() |> normalize()
      else
        {:error, reason} -> normalize_outcome(execution_error(reason))
      end
    after
      try do
        cleanup_stream(cleanup)
      after
        try do
          cleanup_control_transport(cleanup)
        after
          put_execution_lease(previous_lease)
        end
      end
    end
  end

  defp bind_execution(request, context, deadline) do
    authority =
      Map.new(@authority_options, fn {key, option} ->
        {key, Map.get(context, key, request.options[option])}
      end)

    lease =
      Map.get(
        context,
        :execution_lease,
        Process.get(:crawler_execution_lease) || authority.execution_lease
      )

    authority = Map.put(authority, :execution_lease, lease)
    options = Enum.map(@authority_options, fn {key, option} -> {option, authority[key]} end)

    context =
      authority
      |> Map.merge(%{deadline: deadline, crawler_deadline: deadline})
      |> Map.merge(Map.take(context, [:control_accounting, :max_body]))

    {Req.Request.merge_options(request, [{:crawler_deadline, deadline} | options]), context}
  end

  defp put_execution_lease(nil), do: Process.delete(:crawler_execution_lease)
  defp put_execution_lease(lease), do: Process.put(:crawler_execution_lease, lease)

  defp earlier_deadline(nil, deadline), do: deadline
  defp earlier_deadline(deadline, nil), do: deadline
  defp earlier_deadline(left, right), do: if(left.at <= right.at, do: left, else: right)

  defp freeze_steps(request, url) do
    request =
      if request.into == (&stream/2) do
        request
      else
        Req.Request.put_private(request, :crawler_into, request.into)
      end

    %{
      request
      | url: URI.parse(url),
        request_steps: [],
        current_request_steps: [],
        into: &stream/2
    }
  end

  defp prepare_steps(%{request_steps: []} = request), do: {:ok, request}

  defp prepare_steps(%{request_steps: [{_name, step} | rest]} = request) do
    with :ok <- check_deadline(request) do
      case run_step(step, request) do
        %Req.Request{halted: false} = next ->
          prepare_steps(%{next | request_steps: rest})

        %Req.Request{} ->
          {:error, {:request_preparation, :halted}}

        {_request, %Req.Response{}} = result ->
          Body.release(result)
          {:error, {:request_preparation, :short_circuited}}

        {_request, %{__exception__: true} = error} ->
          {:error, error}

        _ ->
          {:error, {:request_preparation, :invalid_step_result}}
      end
    end
  rescue
    _exception -> {:error, {:request_preparation, :step_failed}}
  end

  defp run_step(step, request) when is_function(step, 1), do: step.(request)

  defp run_step({module, function, arguments}, request),
    do: apply(module, function, [request | arguments])

  defp equivalence_options(options) do
    options =
      options
      |> Map.drop([
        :crawler_deadline,
        :crawler_scope,
        :crawler_generation,
        :crawler_queue,
        :crawler_execution_lease,
        :user_agent,
        :base_url,
        :params,
        :path_params,
        :path_params_style,
        :range,
        :form,
        :form_multipart,
        :json,
        :compress_body,
        :aws_sigv4
      ])
      |> Map.update(:crawler_cookie_site, nil, &Crawler.Site.origin/1)

    case options[:auth] do
      {:digest, _userinfo} -> options
      _ -> Map.delete(options, :auth)
    end
  end

  defp opaque?(request) do
    deferred_behavior?(request) or
      Enum.any?(request.request_steps, fn {name, step} ->
        not builtin?(step, name, @request_steps)
      end) or
      Enum.any?(request.response_steps, fn {name, step} ->
        not builtin?(step, name, @response_steps)
      end) or
      Enum.any?(request.error_steps, fn {name, step} -> not builtin?(step, name, [:retry]) end)
  end

  defp deferred_behavior?(request) do
    not builtin_adapter?(request.adapter) or
      request.options[:finch_request] not in [nil, &Crawler.HTTP.Stream.stream/4] or
      request.into not in [nil, &stream/2, &Body.stream/2] or
      not (is_nil(request.body) or is_binary(request.body) or is_list(request.body)) or
      is_function(request.options[:retry]) or is_function(request.options[:retry_delay])
  end

  defp builtin_adapter?(adapter) when is_function(adapter, 1) do
    info = Function.info(adapter)
    info[:module] == Req.Steps and info[:name] in [:run_finch, :run_plug] and info[:env] == []
  end

  defp builtin_adapter?({Req.Steps, name, []}) when name in [:run_finch, :run_plug], do: true
  defp builtin_adapter?(_adapter), do: false

  defp builtin?(step, name, names) when name in @request_steps or name in @response_steps do
    name in names and step == Function.capture(Req.Steps, step_function(name), 1)
  end

  defp builtin?(_step, _name, _names), do: false
  defp step_function(:http_digest), do: :handle_http_digest
  defp step_function(name), do: name

  defp pipeline(request) do
    cookie_limits = Req.Request.get_private(request, :crawler_cookie_limits)

    response_steps =
      request.response_steps
      |> Keyword.drop([:decompress_body, :decode_body])
      |> Keyword.replace(:retry, &retry/1)
      |> Keyword.replace(:redirect, &follow_redirect/1)

    request =
      request
      |> Map.put(:response_steps, response_steps)
      |> Map.update!(:error_steps, &Keyword.replace(&1, :retry, fn result -> retry(result) end))
      |> Req.Request.prepend_response_steps(
        crawler_body: &finish_body/1,
        crawler_cookies: fn result -> capture_cookies(result, cookie_limits) end,
        crawler_redirect: &guard_redirect/1
      )
      |> Req.Request.append_response_steps(crawler_final_url: &capture_final_url/1)
      |> Transport.install()

    %{request | adapter: &transport/1}
  end

  @doc false
  def stream(event, {request, _response} = acc) do
    case Body.stream(event, acc) do
      {:cont, {_request, %Req.Response{}} = next} ->
        track_stream(request, next)

        continue_stream(request, event, next)

      {action, next} ->
        track_stream(request, next)
        {action, next}
    end
  end

  defp continue_stream(request, event, next) do
    case Req.Request.get_private(request, :crawler_into) do
      callback when is_function(callback, 2) ->
        if callback == (&Body.stream/2), do: {:cont, next}, else: callback.(event, next)

      _ ->
        {:cont, next}
    end
  end

  defp track_stream(request, result) do
    if cleanup = Req.Request.get_private(request, :crawler_cleanup),
      do: Process.put(cleanup, result)
  end

  defp finish_body({request, _response} = result) do
    result = Body.finish(result)
    if cleanup = Req.Request.get_private(request, :crawler_cleanup), do: Process.delete(cleanup)
    account_control_result(result)
  end

  @doc false
  def transport(request) do
    request = restore_redirect_logging(request)

    with :ok <- check_execution(request),
         :ok <- start_control_transport(request) do
      {returned, response} = run_transport(request)

      returned =
        %{returned | adapter: &transport/1}
        |> Req.Request.put_private(
          :crawler_execution_context,
          Req.Request.get_private(request, :crawler_execution_context)
        )
        |> Req.Request.put_private(
          :crawler_cleanup,
          Req.Request.get_private(request, :crawler_cleanup)
        )
        |> Req.Request.put_private(
          :crawler_cookie_limits,
          Req.Request.get_private(request, :crawler_cookie_limits)
        )

      cleanup_failed_transport(request, returned, response)

      case check_execution(returned) do
        :ok ->
          if match?(%Req.Response{}, response),
            do: {returned, response},
            else: account_control_result({returned, response})

        {:error, reason} ->
          Body.release({returned, response})

          if cleanup = Req.Request.get_private(returned, :crawler_cleanup),
            do: Process.delete(cleanup)

          account_control_result({returned, execution_error(reason)})
      end
    else
      {:error, reason} -> Req.Request.halt(request, control_error(reason))
    end
  end

  defp cleanup_failed_transport(_request, _returned, %Req.Response{}), do: :ok

  defp cleanup_failed_transport(request, returned, _response) do
    if cleanup = Req.Request.get_private(returned, :crawler_cleanup) do
      if released_by_stream?(request),
        do: Process.delete(cleanup),
        else: cleanup_stream(cleanup)
    end
  end

  defp start_control_transport(request) do
    context = Req.Request.get_private(request, :crawler_execution_context, %{})

    if context[:control_accounting] == true do
      with :ok <- Store.control_transport_started(context) do
        cleanup = Req.Request.get_private(request, :crawler_cleanup)
        Process.put({cleanup, :control_transport}, request)
        :ok
      end
    else
      :ok
    end
  end

  defp finish_control_transport(request, {_returned, outcome} = result) do
    cleanup = Req.Request.get_private(request, :crawler_cleanup)

    case Process.delete({cleanup, :control_transport}) do
      nil ->
        result

      active ->
        context = Req.Request.get_private(active, :crawler_execution_context)
        finish_control_result(request, outcome, result, context)
    end
  end

  defp finish_control_result(request, outcome, result, context) do
    case Store.control_transport_finished(context) do
      :ok ->
        result

      {:error, reason} ->
        if execution_failure?(outcome) or match?(%ControlAccountingRejected{}, outcome),
          do: result,
          else: Req.Request.halt(request, control_error(reason))
    end
  end

  defp cleanup_control_transport(cleanup) do
    if request = Process.get({cleanup, :control_transport}) do
      account_control_result({request, :unknown_failure})
    end
  end

  defp control_error(:stale), do: execution_error(:stale)
  defp control_error({:deadline, _kind} = reason), do: execution_error(reason)
  defp control_error(reason), do: %ControlAccountingRejected{reason: reason}

  defp run_transport(request) do
    Transport.run(%{request | adapter: &Transport.run/1})
  catch
    kind, reason ->
      failure = if execution_failure?(reason), do: reason, else: :unknown_failure

      case account_control_result({request, failure}) do
        {_request, %ControlAccountingRejected{}} = result -> result
        _ -> :erlang.raise(kind, reason, __STACKTRACE__)
      end
  end

  defp account_control_result({request, _outcome} = result) do
    try do
      finish_control_transport(request, do_account_control_result(result))
    after
      finish_control_transport(request, result)
    end
  end

  defp do_account_control_result({_request, %ControlAccountingRejected{}} = result), do: result

  defp do_account_control_result({request, outcome} = result) do
    context = Req.Request.get_private(request, :crawler_execution_context, %{})

    if context[:control_accounting] == true do
      sequence = Process.get(@control_sequence, 0) + 1
      Process.put(@control_sequence, sequence)

      bytes =
        if match?(%Req.Response{}, outcome), do: byte_size(outcome.body), else: :unknown_failure

      case Store.account_control_entity(context, sequence, bytes) do
        :ok ->
          if match?(%Req.Response{}, outcome),
            do: {request, Req.Response.put_private(outcome, :crawler_control_sequence, sequence)},
            else: result

        {:error, reason} ->
          if execution_failure?(outcome),
            do: result,
            else: Req.Request.halt(request, %ControlAccountingRejected{reason: reason})
      end
    else
      result
    end
  end

  defp execution_failure?(%{__struct__: module}),
    do: module in [Crawler.HTTP.DeadlineExceeded, StaleExecution]

  defp execution_failure?(_outcome), do: false

  defp released_by_stream?(request) do
    adapter = Req.Request.get_private(request, :crawler_transport_adapter)
    callback = request.options[:finch_request]

    adapter in [&Req.Steps.run_finch/1, {Req.Steps, :run_finch, []}] and
      (not is_function(callback, 4) or callback == (&Crawler.HTTP.Stream.stream/4))
  end

  defp cleanup_stream(cleanup) do
    case Process.delete(cleanup) do
      nil -> :ok
      result -> Body.release(result)
    end
  end

  defp normalize({request, %Req.Response{} = response}) do
    with :ok <- check_execution(request),
         {:ok, request} <- validate_cookie_proof(request),
         :ok <- check_execution(request) do
      {:ok, Req.Response.put_private(response, :crawler_reuse, reuse_disposition(request))}
    end
  end

  defp normalize({request, outcome}) do
    with :ok <- check_execution(request), do: normalize_outcome(outcome)
  end

  defp normalize_outcome(%{__struct__: Crawler.HTTP.DeadlineExceeded, kind: kind}),
    do: {:error, {:deadline, kind}}

  defp normalize_outcome(%{__struct__: Crawler.HTTP.BodyLimitExceeded, key: key}),
    do: {:error, {:limit, key}}

  defp normalize_outcome(%StaleExecution{}), do: {:error, :stale}

  defp normalize_outcome(%ControlAccountingRejected{reason: reason}), do: {:error, reason}

  defp normalize_outcome(%CookieStorageRejected{reason: reason}), do: {:error, reason}

  defp normalize_outcome(error), do: {:error, error}

  defp check_deadline(request) do
    case request.options[:crawler_deadline] do
      nil -> :ok
      %Deadline{} = deadline -> Deadline.check(deadline)
    end
  end

  defp check_execution(request) do
    with :ok <- check_deadline(request) do
      scope = request.options[:crawler_scope]
      generation = request.options[:crawler_generation]
      queue = request.options[:crawler_queue]
      lease = request.options[:crawler_execution_lease]

      cond do
        is_nil(generation) and is_nil(lease) ->
          :ok

        not Authority.current?(scope, generation, queue, lease) ->
          {:error, :stale}

        is_reference(lease) and not Authority.execution_current?(lease, self()) ->
          {:error, :stale}

        true ->
          :ok
      end
    end
  end

  defp execution_error(:stale), do: %StaleExecution{}
  defp execution_error({:deadline, _kind} = reason), do: deadline_error(reason)

  defp deadline_error({:deadline, kind}),
    do: struct(Crawler.HTTP.DeadlineExceeded, kind: kind, reason: {:deadline, kind})

  defp resolve(url), do: resolve_url(URI.to_string(url))

  @doc false
  def resolve_url(url) do
    case URL.resolve(url, nil) do
      {:ok, target} -> {:ok, target}
      :skip -> {:error, %InvalidURL{url: url}}
    end
  end

  defp capture_final_url({request, %Req.Response{} = response}) do
    {request, Req.Response.put_private(response, :crawler_url, URI.to_string(request.url))}
  end

  defp capture_cookies({request, %Req.Response{} = response}, cookie_limits) do
    request = Req.Request.put_private(request, :crawler_cookie_limits, cookie_limits)
    result = {request, response}
    scope = request.options[:crawler_scope]
    headers = Req.Response.get_header(response, "set-cookie")

    if scope && headers != [] do
      case Store.save_cookies_with_proof(
             scope,
             URI.to_string(request.url),
             headers,
             request.options[:crawler_generation],
             cookie_context(request),
             cookie_proof(request)
           ) do
        {:ok, observation} -> {observe_cookie_proof(request, observation), response}
        {:error, :stale} -> Req.Request.halt(request, %StaleExecution{})
        {:error, reason} -> Req.Request.halt(request, %CookieStorageRejected{reason: reason})
      end
    else
      result
    end
  end

  defp guard_redirect({request, %Req.Response{status: status} = response} = result)
       when status in @redirect_statuses do
    if request.options[:redirect] != false and hops_remaining?(request) do
      case first_location(response) do
        nil -> {request, Req.Response.delete_header(response, "location")}
        location -> review_redirect(request, response, location)
      end
    else
      result
    end
  end

  defp guard_redirect(result), do: result

  defp follow_redirect({request, response}) do
    level = Req.Request.get_option(request, :redirect_log_level, false)

    if level != false and request.options[:redirect] != false and
         response.status in @redirect_statuses and hops_remaining?(request) do
      if location = first_location(response),
        do: Logger.log(level, ["redirecting to ", Diagnostics.url(location)])
    end

    request =
      request
      |> Req.Request.put_private(:crawler_redirect_log_level, level)
      |> Req.Request.put_option(:redirect_log_level, false)

    {request, outcome} = Req.Steps.redirect({request, response})
    {restore_redirect_logging(request), outcome}
  end

  defp restore_redirect_logging(request) do
    case Map.fetch(request.private, :crawler_redirect_log_level) do
      {:ok, level} -> Req.Request.put_option(request, :redirect_log_level, level)
      :error -> request
    end
  end

  defp hops_remaining?(request) do
    Req.Request.get_private(request, :req_redirect_count, 0) <
      Req.Request.get_option(request, :max_redirects, 10)
  end

  defp first_location(response) do
    case Req.Response.get_header(response, "location") do
      [location | _] when is_binary(location) -> if URL.sanitize(location) != "", do: location
      _ -> nil
    end
  end

  defp review_redirect(request, response, location) do
    allow = Req.Request.get_private(request, :crawler_allow_redirect)
    context = Req.Request.get_private(request, :crawler_execution_context)

    with :ok <- check_execution(request),
         {:ok, next} <- URL.resolve(location, URI.to_string(request.url)),
         true <- allow.(next, context),
         :ok <- check_execution(request) do
      request =
        if same_host?(request.url, next) do
          request
        else
          request |> keep_headers() |> Req.Request.merge_options(crawler_user_cookie: nil)
        end

      case put_cookie(request, next, cookie_proof(request)) do
        {:ok, request, observation} ->
          request =
            request |> mark_cookie_dependency() |> observe_cookie_proof(observation)

          {request, Req.Response.put_header(response, "location", next)}

        {:error, :stale} ->
          Req.Request.halt(request, %StaleExecution{})
      end
    else
      {:error, {:limit, key} = reason} ->
        Req.Request.halt(request, %Crawler.HTTP.BodyLimitExceeded{key: key, reason: reason})

      {:error, {:deadline, _} = reason} ->
        Req.Request.halt(request, deadline_error(reason))

      {:error, :stale} ->
        Req.Request.halt(request, %StaleExecution{})

      _ ->
        Req.Request.halt(request, %RedirectRejected{url: location})
    end
  end

  defp put_cookie(request, url, expected_proof) do
    context = cookie_context(request)
    scope = request.options[:crawler_scope]
    user = if Cookies.caller_cookie?(url, context), do: request.options[:crawler_user_cookie]

    snapshot =
      if is_nil(scope),
        do: {:ok, nil, nil},
        else:
          Store.cookie_snapshot(
            scope,
            url,
            request.options[:crawler_generation],
            context,
            expected_proof
          )

    with {:ok, jar, observation} <- snapshot do
      request =
        case Cookies.merge_header(user, jar) do
          nil -> Req.Request.delete_header(request, "cookie")
          header -> Req.Request.put_header(request, "cookie", header)
        end

      {:ok, request, observation}
    end
  end

  defp cookie_proof(request), do: cookie_trace(request).proof

  defp cookie_trace(request) do
    Req.Request.get_private(request, :crawler_cookie_trace, %{
      proof: :unbound,
      reason: :cookie_proof_unproven,
      dependent?: false,
      opaque?: true
    })
  end

  defp validate_cookie_proof(request) do
    if cookie_jar?(request) do
      case Store.validate_cookie_proof(
             request.options[:crawler_scope],
             request.options[:crawler_generation],
             cookie_context(request),
             cookie_proof(request)
           ) do
        {:ok, observation} -> {:ok, observe_cookie_proof(request, observation)}
        {:error, :stale} -> {:error, :stale}
      end
    else
      {:ok, request}
    end
  end

  defp observe_cookie_proof(request, nil), do: request

  defp observe_cookie_proof(request, %Observation{verdict: :current, effect: :unchanged}),
    do: request

  defp observe_cookie_proof(request, %Observation{} = observation) do
    trace = cookie_trace(request)

    reason =
      if observation.verdict == :changed or observation.effect == :changed,
        do: :cookie_state_changed,
        else: :cookie_proof_unproven

    Req.Request.put_private(request, :crawler_cookie_trace, %{
      trace
      | reason: trace.reason || reason
    })
  end

  defp mark_cookie_dependency(request) do
    if cookie_jar?(request) do
      trace = cookie_trace(request)
      Req.Request.put_private(request, :crawler_cookie_trace, %{trace | dependent?: true})
    else
      request
    end
  end

  defp cookie_jar?(request) do
    not is_nil(request.options[:crawler_scope]) and
      Req.Request.get_option(request, :crawler_cookie_credentials, :include) != :omit
  end

  defp reuse_disposition(request) do
    trace = cookie_trace(request)
    dependency = if trace.dependent?, do: {:redirect_jar, trace.proof}, else: :initial
    reason = if trace.opaque?, do: :opaque_behavior, else: if(trace.dependent?, do: trace.reason)

    %ReuseDisposition{
      dependency: dependency,
      disposition: if(reason, do: :private, else: :candidate),
      reason: reason
    }
  end

  defp cookie_value(request) do
    case Req.Request.get_header(request, "cookie") do
      [] -> nil
      values -> Enum.join(values, "; ")
    end
  end

  defp cookie_context(request) do
    Map.merge(Req.Request.get_private(request, :crawler_cookie_limits), %{
      queue: request.options[:crawler_queue],
      site: request.options[:crawler_cookie_site] || URI.to_string(request.url),
      navigation: Req.Request.get_option(request, :crawler_cookie_navigation, true),
      credentials: Req.Request.get_option(request, :crawler_cookie_credentials, :include)
    })
  end

  @doc false
  def same_host?(left, right) do
    case {hostname(left), hostname(right)} do
      {host, host} when is_binary(host) -> true
      _ -> false
    end
  end

  defp hostname(%URI{host: host}) when is_binary(host) and host != "", do: String.downcase(host)
  defp hostname(url) when is_binary(url), do: hostname(URI.parse(url))
  defp hostname(_url), do: nil

  defp keep_headers(request) do
    request = Req.Request.delete_option(request, :auth)

    request.headers
    |> Req.Fields.get_list()
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.reduce(request, fn name, request ->
      if String.downcase(to_string(name)) in @safe_redirect_headers,
        do: request,
        else: Req.Request.delete_header(request, name)
    end)
  end

  defp retry({request, outcome} = result) do
    cond do
      terminal_error?(outcome) -> result
      is_nil(request.options[:crawler_deadline]) -> Req.Steps.retry(result)
      true -> retry_with_deadline(result)
    end
  end

  defp retry_with_deadline({request, outcome} = result) do
    with :ok <- check_execution(request),
         decision when decision not in [false, nil] <- retry?(request, outcome),
         count = Req.Request.get_private(request, :req_retry_count, 0),
         true <- count < Req.Request.get_option(request, :max_retries, 3),
         delay = retry_delay(request, outcome, decision, count),
         :ok <- pause(request, delay) do
      request = Req.Request.put_private(request, :req_retry_count, count + 1)
      {request, outcome} = Req.Request.run_request(%{request | halted: false})
      Req.Request.halt(request, outcome)
    else
      {:error, {:deadline, _} = reason} -> Req.Request.halt(request, deadline_error(reason))
      {:error, :stale} -> Req.Request.halt(request, %StaleExecution{})
      _ -> result
    end
  end

  defp terminal_error?(%{__struct__: module}) do
    module in [
      Crawler.HTTP.BodyTooLarge,
      Crawler.HTTP.BodyLimitExceeded,
      Crawler.HTTP.UnsupportedEncoding,
      Crawler.HTTP.DeadlineExceeded,
      ControlAccountingRejected,
      CookieStorageRejected,
      StaleExecution,
      RedirectRejected
    ]
  end

  defp terminal_error?(_outcome), do: false

  defp retry?(request, outcome) do
    case Req.Request.get_option(request, :retry, :safe_transient) do
      false ->
        false

      :never ->
        false

      mode when mode in [:safe_transient, :safe] ->
        request.method in [:get, :head] and transient?(outcome)

      :transient ->
        transient?(outcome)

      fun when is_function(fun, 2) ->
        fun.(request, outcome)

      fun when is_function(fun, 1) ->
        fun.(outcome)

      _ ->
        raise ArgumentError, "invalid retry option"
    end
  end

  defp transient?(%Req.Response{status: status}), do: status in [408, 429, 500, 502, 503, 504]

  defp transient?(%Req.TransportError{reason: reason}),
    do: reason in [:timeout, :econnrefused, :closed]

  defp transient?(%Req.HTTPError{protocol: :http2, reason: reason}),
    do: reason in [:unprocessed, :pool_not_available]

  defp transient?(_outcome), do: false

  defp retry_delay(request, outcome, decision, count) do
    case decision do
      {:delay, delay} ->
        if request.options[:retry_delay],
          do: raise(ArgumentError, "retry_delay cannot accompany a retry delay result")

        delay

      true ->
        retry_after(outcome) || configured_delay(request, count)
    end
  end

  defp retry_after(%Req.Response{status: status} = response) when status in [429, 503],
    do: Req.Response.get_retry_after(response)

  defp retry_after(_outcome), do: nil

  defp configured_delay(request, count) do
    case Req.Request.get_option(request, :retry_delay, fn n -> Integer.pow(2, n) * 1000 end) do
      delay when is_integer(delay) and delay >= 0 -> delay
      fun when is_function(fun, 1) -> fun.(count)
    end
  end

  defp pause(request, delay) when is_integer(delay) and delay >= 0 do
    case request.options[:crawler_deadline] do
      nil -> Process.sleep(delay)
      deadline -> Process.sleep(min(delay, Deadline.remaining(deadline)))
    end

    check_execution(request)
  end
end
