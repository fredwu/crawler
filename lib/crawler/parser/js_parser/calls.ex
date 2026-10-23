defmodule Crawler.Parser.JsParser.Calls do
  @moduledoc false

  alias Crawler.Analysis.Budget
  alias Crawler.Parser.JsParser.Matches
  alias Crawler.Parser.JsParser.Scanner
  alias Crawler.Parser.JsParser.StringLiteral

  # UTF-8 bytes for the scanner's non-ASCII whitespace. Byte mode keeps a
  # script that is not UTF-8 scannable; the mask still rejects a Unicode name.
  @gap "(?:[\\t\\n\\r\\f\\x0B ]|\\xC2\\xA0|\\xE1\\x9A\\x80|\\xE2\\x80[\\x80-\\x8A\\xA8\\xA9\\xAF]|\\xE2\\x81\\x9F|\\xE3\\x80\\x80|\\xEF\\xBB\\xBF)"
  @worker Regex.compile!("(?<![\\w$.])new#{@gap}+(SharedWorker|Worker)#{@gap}*(\\()")
  @register Regex.compile!(
              "(?<![\\w$.])(?:window#{@gap}*\\.#{@gap}*)?navigator#{@gap}*\\.#{@gap}*serviceWorker#{@gap}*\\.#{@gap}*register#{@gap}*(\\()"
            )
  @meta_url Regex.compile!("(?<![\\w$.])new#{@gap}+URL#{@gap}*(\\()")
  @worker_url_open Regex.compile!("^new#{@gap}+URL#{@gap}*\\(")
  @meta_base Regex.compile!(
               "^#{@gap}*,#{@gap}*import#{@gap}*\\.#{@gap}*meta#{@gap}*\\.#{@gap}*url#{@gap}*\\)"
             )
  @self_location_base Regex.compile!(
                        "^#{@gap}*,#{@gap}*self#{@gap}*\\.#{@gap}*location#{@gap}*\\.#{@gap}*href#{@gap}*\\)"
                      )
  @location_base Regex.compile!("^#{@gap}*,#{@gap}*location#{@gap}*\\.#{@gap}*href#{@gap}*\\)")
  @document_base Regex.compile!("^#{@gap}*,#{@gap}*document#{@gap}*\\.#{@gap}*baseURI#{@gap}*\\)")
  # `self.location.href` is tried before `location.href`. Both name the same base.
  @known_bases [
    {:location, @self_location_base},
    {:location, @location_base},
    {:document, @document_base},
    {:script, @meta_base}
  ]
  # A worklet and `importScripts` keep `import.meta.url` in a classic script.
  # A worker, service worker, and `import()` do not.
  @entry_bases [:script, :location, :document]
  @import_scripts Regex.compile!("(?<![\\w$.])importScripts#{@gap}*(\\()")
  @import_call Regex.compile!("(?<![\\w$.])import#{@gap}*(\\()")
  @ident "[A-Za-z_$][A-Za-z0-9_$]*"
  @worklet Regex.compile!(
             "(?<![\\w$])(?:(?:#{@ident}#{@gap}*\\.#{@gap}*)?CSS#{@gap}*\\.#{@gap}*paintWorklet|(?:#{@ident}#{@gap}*\\.#{@gap}*)+audioWorklet)#{@gap}*\\.#{@gap}*addModule#{@gap}*(\\()"
           )

  # The scanner keeps `import` visible and masks every other identifier, so
  # these calls are matched on the original source. Paren depth still uses the
  # mask, where string and comment contents are spaces.
  def spans(source, goal) when is_binary(source) and goal in [:script, :module] do
    spans(source, goal, Scanner.scan(source, goal))
  end

  def spans(_source, _goal), do: []

  def spans(source, goal, scan) when is_binary(source) and goal in [:script, :module] do
    {:ok, spans, _budget} = spans_result(source, goal, scan, Budget.unlimited())
    spans
  end

  def spans_result(source, goal, {masked, strings, _comments}, budget)
      when is_binary(source) and goal in [:script, :module] do
    scratch =
      byte_size(source) * (Budget.cost(:token) + Budget.cost(:frame)) +
        Budget.cost(:context, 8)

    with {:ok, budget} <- Budget.reserve(budget, scratch) do
      strings = MapSet.new(strings)
      {workers, state} = workers(source, masked, strings, goal, {budget, 0})
      {scripts, state} = import_scripts(source, masked, strings, state)
      {imports, state} = dynamic_imports(source, masked, strings, goal, state)
      taken = taken_spans(workers, scripts, imports)
      {urls, {budget, retained}} = module_urls(source, masked, strings, goal, taken, state)
      spans = workers ++ urls ++ scripts ++ imports

      with {:ok, budget} <- Budget.settle(budget, scratch, retained) do
        {:ok, spans, budget}
      end
    end
  catch
    {:js_calls_budget, error} -> error
  end

  defp workers(source, masked, strings, goal, state) do
    {worker, state} =
      constructed(@worker, source, masked, strings, :worker, allowed_bases(goal), state)

    {worklet, state} =
      constructed(@worklet, source, masked, strings, :worklet, @entry_bases, state)

    {register, state} =
      constructed(@register, source, masked, strings, :register, allowed_bases(goal), state)

    {worker_strings, state} = worker_strings(source, masked, strings, state)
    {worklet_strings, state} = worklet_strings(source, masked, strings, state)
    {registers, state} = registers(source, masked, strings, state)
    {worker ++ worklet ++ register ++ worker_strings ++ worklet_strings ++ registers, state}
  end

  defp constructed(regex, source, masked, strings, kind, bases, state) do
    {matches, state} =
      scan(regex, source, &constructed_call(&1, source, masked, strings, kind, bases), state)

    reject_overlaps(matches, state)
  end

  defp constructed_call([whole, kind_name, paren], source, masked, strings, kind, bases)
       when is_tuple(kind_name) do
    constructed_call([whole, paren], source, masked, strings, kind, bases)
  end

  defp constructed_call([whole, paren], source, masked, strings, kind, bases) do
    open = index(paren)

    with true <- call?(masked, strings, whole, paren),
         {:ok, url_open} <- worker_url_open(source, masked, open),
         {:ok, {at, len, text}, next} <- first_string(masked, source, strings, url_open),
         {:ok, url_close, base} <- known_base_end(source, next, bases),
         true <- literal_argument?(masked, {url_close, 0}),
         {:ok, close} <- call_end(masked, open) do
      worker_tuple(at, len, text, base, kind, source, strings, masked, open, close)
    else
      _ -> nil
    end
  end

  defp constructed_call(_groups, _source, _masked, _strings, _kind, _bases), do: nil

  defp worker_strings(source, masked, strings, state) do
    scan(
      @worker,
      source,
      fn [whole, _kind, paren] ->
        open = index(paren)

        with true <- call?(masked, strings, whole, paren),
             {:ok, {at, len, text}, _next} <- first_string(masked, source, strings, open),
             true <- literal_argument?(masked, {at, len}),
             {:ok, close} <- call_end(masked, open) do
          worker_tuple(at, len, text, :window, :worker, source, strings, masked, open, close)
        else
          _ -> nil
        end
      end,
      state
    )
  end

  defp worklet_strings(source, masked, strings, state) do
    scan(
      @worklet,
      source,
      fn [whole, paren] ->
        open = index(paren)

        with true <- call?(masked, strings, whole, paren),
             {:ok, {at, len, text}, _next} <- first_string(masked, source, strings, open),
             true <- literal_argument?(masked, {at, len}),
             {:ok, close} <- call_end(masked, open) do
          worker_tuple(at, len, text, :window, :worklet, source, strings, masked, open, close)
        else
          _ -> nil
        end
      end,
      state
    )
  end

  defp registers(source, masked, strings, state) do
    scan(
      @register,
      source,
      fn [whole, paren] ->
        open = index(paren)

        with true <- call?(masked, strings, whole, paren),
             {:ok, {at, len, text}, _next} <- first_string(masked, source, strings, open),
             true <- literal_argument?(masked, {at, len}),
             {:ok, close} <- call_end(masked, open) do
          worker_tuple(at, len, text, :window, :register, source, strings, masked, open, close)
        else
          _ -> nil
        end
      end,
      state
    )
  end

  defp module_urls(source, masked, strings, :module, taken, state) do
    {urls, state} = urls(source, masked, strings, state)

    {kept, state} =
      Enum.reduce(urls, {[], state}, fn {:url, at, len, _spec} = call,
                                        {kept, {budget, retained}} ->
        if MapSet.member?(taken, {at, len}),
          do: {kept, {budget, retained - call_bytes(call)}},
          else: {[call | kept], {budget, retained}}
      end)

    {Enum.reverse(kept), state}
  end

  defp module_urls(_source, _masked, _strings, _goal, _taken, state), do: {[], state}

  defp taken_spans(workers, scripts, imports) do
    MapSet.new(span_keys(workers) ++ span_keys(scripts) ++ span_keys(imports))
  end

  defp span_keys(calls) do
    Enum.flat_map(calls, fn
      {:worker, at, len, _, _, _, _} -> [{at, len}]
      {:scripts, at, len, _, _} -> [{at, len}]
      {:import, at, len, _, _} -> [{at, len}]
      _other -> []
    end)
  end

  defp urls(source, masked, strings, state) do
    scan(
      @meta_url,
      source,
      fn [whole, paren] ->
        with true <- call?(masked, strings, whole, paren),
             {:ok, {at, len, text}, next} <- first_string(masked, source, strings, index(paren)),
             {:ok, _close, :script} <- known_base_end(source, next, [:script]) do
          {:url, at, len, text}
        else
          _ -> nil
        end
      end,
      state
    )
  end

  defp dynamic_imports(source, masked, strings, goal, state) do
    scan(@import_call, source, &import_call(&1, source, masked, strings, goal), state)
  end

  defp import_call([whole, paren], source, masked, strings, goal) do
    open = index(paren)

    with true <- call?(masked, strings, whole, paren),
         {:ok, url_open} <- worker_url_open(source, masked, open),
         {:ok, {at, len, text}, next} <- first_string(masked, source, strings, url_open),
         {:ok, url_close, base} <- known_base_end(source, next, allowed_bases(goal)),
         true <- literal_argument?(masked, {url_close, 0}),
         {:ok, _close} <- call_end(masked, open) do
      {:import, at, len, text, base}
    else
      _ -> nil
    end
  end

  defp import_scripts(source, masked, strings, state) do
    scan(
      @import_scripts,
      source,
      fn groups, state ->
        script_call(groups, source, masked, strings, state)
      end,
      state
    )
  end

  defp script_call([whole, paren], source, masked, strings, state) do
    if call?(masked, strings, whole, paren) do
      script_arguments(source, masked, strings, paren, state)
    else
      {[], state}
    end
  end

  defp script_arguments(source, masked, strings, paren, state) do
    case call_end(masked, index(paren)) do
      {:ok, close} -> arguments(masked, source, strings, index(paren) + 1, close, [], state)
      :error -> {[], state}
    end
  end

  defp arguments(masked, source, strings, index, stop, acc, state) do
    index = skip(masked, index, stop)

    cond do
      index >= stop ->
        {Enum.reverse(acc), state}

      :binary.at(masked, index) == ?, ->
        arguments(masked, source, strings, index + 1, stop, acc, state)

      :binary.at(masked, index) in [?", ?', ?`] ->
        string_argument(masked, source, strings, index, stop, acc, state)

      true ->
        script_url_argument(masked, source, strings, index, stop, acc, state)
    end
  end

  defp string_argument(masked, source, strings, index, stop, acc, state) do
    state = count(state)

    case one_string(masked, source, strings, index, stop) do
      {:ok, {at, len, text}, next} ->
        literal_scripts(masked, source, strings, at, len, text, next, stop, acc, state)

      {:skip, next} ->
        arguments(masked, source, strings, next, stop, acc, state)

      :error ->
        {Enum.reverse(acc), state}
    end
  end

  defp literal_scripts(masked, source, strings, at, len, text, next, stop, acc, state) do
    if literal_argument?(masked, {at, len}) do
      arguments(masked, source, strings, next, stop, [{:scripts, at, len, text} | acc], state)
    else
      arguments(masked, source, strings, skip_argument(masked, next, stop), stop, acc, state)
    end
  end

  defp script_url_argument(masked, source, strings, index, stop, acc, state) do
    state = count(state)

    case script_url(source, masked, strings, index) do
      {:ok, {at, len, text, base}, next} ->
        arguments(
          masked,
          source,
          strings,
          next,
          stop,
          [{:scripts, at, len, text, base} | acc],
          state
        )

      :error ->
        arguments(masked, source, strings, skip_argument(masked, index, stop), stop, acc, state)
    end
  end

  defp script_url(source, masked, strings, index) do
    with {:ok, url_open} <- url_open_at(source, masked, index),
         {:ok, {at, len, text}, next} <- first_string(masked, source, strings, url_open),
         {:ok, url_close, base} <- known_base_end(source, next, @entry_bases),
         true <- literal_argument?(masked, {url_close, 0}) do
      {:ok, {at, len, text, base}, url_close + 1}
    else
      _ -> :error
    end
  end

  defp one_string(masked, source, strings, index, stop) do
    mark = :binary.at(masked, index)
    at = index + 1

    if at >= stop do
      :error
    else
      matched_string(masked, source, strings, at, stop - at, mark)
    end
  end

  defp matched_string(masked, source, strings, at, length, mark) do
    case :binary.match(binary_part(masked, at, length), <<mark>>) do
      {len, _match} -> decoded_string(source, strings, at, len)
      :nomatch -> :error
    end
  end

  defp decoded_string(source, strings, at, len) do
    next = at + len + 1

    if MapSet.member?(strings, {at, at + len}) do
      decode_text(source, at, len, next)
    else
      {:skip, next}
    end
  end

  defp decode_text(source, at, len, next) do
    case StringLiteral.decode(binary_part(source, at, len)) do
      {:ok, text} -> {:ok, {at, len, text}, next}
      :error -> {:skip, next}
    end
  end

  defp first_string(masked, source, strings, open) do
    index = skip(masked, open + 1, byte_size(masked))

    if index < byte_size(masked) and :binary.at(masked, index) in [?", ?', ?`] do
      one_string(masked, source, strings, index, byte_size(masked))
    else
      :error
    end
  end

  defp worker_url_open(source, masked, open) do
    url_open_at(source, masked, skip(masked, open + 1, byte_size(masked)))
  end

  defp url_open_at(source, masked, index) when index < byte_size(source) do
    rest = binary_part(source, index, byte_size(source) - index)
    opened_url(masked, index, Regex.run(@worker_url_open, rest, return: :index))
  end

  defp url_open_at(_source, _masked, _index), do: :error

  defp opened_url(masked, index, [{0, len}]) do
    paren = index + len - 1
    if :binary.at(masked, paren) == ?(, do: {:ok, paren}, else: :error
  end

  defp opened_url(_masked, _index, _match), do: :error

  defp known_base_end(source, index, allowed) do
    rest = binary_part(source, index, byte_size(source) - index)
    find_base(rest, index, allowed, @known_bases)
  end

  defp find_base(_rest, _index, _allowed, []), do: :error

  defp find_base(rest, index, allowed, [{kind, regex} | bases]) do
    if kind in allowed do
      matched_base(rest, index, allowed, bases, kind, regex)
    else
      find_base(rest, index, allowed, bases)
    end
  end

  defp matched_base(rest, index, allowed, bases, kind, regex) do
    case Regex.run(regex, rest, return: :index) do
      [{0, len}] -> {:ok, index + len - 1, kind}
      _other -> find_base(rest, index, allowed, bases)
    end
  end

  defp allowed_bases(:module), do: [:script, :location, :document]
  defp allowed_bases(_goal), do: [:location, :document]

  defp literal_argument?(masked, {at, len}) do
    index = skip(masked, at + len + 1, byte_size(masked))
    index < byte_size(masked) and :binary.at(masked, index) in [?,, ?)]
  end

  defp worker_tuple(at, len, text, base, kind, source, strings, masked, open, close) do
    {goal, credentials} = entry_options(kind, source, strings, masked, open, close)
    {:worker, at, len, text, goal, base, credentials}
  end

  defp entry_options(kind, source, strings, masked, open, close) do
    {parsed, credentials} = worker_goal(source, strings, masked, open, close)
    {goal_for(kind, parsed), credentials_for(kind, parsed, credentials)}
  end

  defp goal_for(:worklet, _parsed), do: :module
  defp goal_for(_kind, parsed), do: parsed

  defp credentials_for(:register, _parsed, _credentials), do: :same_origin
  defp credentials_for(:worklet, _parsed, credentials), do: credentials
  defp credentials_for(_kind, :module, credentials), do: credentials
  defp credentials_for(_kind, _parsed, _credentials), do: :same_origin

  defp worker_goal(source, strings, masked, open, close) do
    case options_brace(masked, open, close) do
      {start, stop} ->
        scan_options(source, strings, masked, start + 1, stop, 1, 0, 0, :script, :same_origin)

      nil ->
        {:script, :same_origin}
    end
  end

  defp options_brace(masked, open, close) do
    case separator(masked, open + 1, close, 0) do
      nil -> nil
      comma -> brace_at(masked, comma, close)
    end
  end

  defp brace_at(masked, comma, close) do
    start = skip(masked, comma + 1, close)

    if start < close and :binary.at(masked, start) == ?{ do
      brace_span(masked, start, close)
    else
      nil
    end
  end

  defp brace_span(masked, start, close) do
    case brace_end(masked, start + 1, close, 1) do
      nil -> nil
      stop -> {start, stop}
    end
  end

  defp separator(_masked, index, stop, _depth) when index >= stop, do: nil

  defp separator(masked, index, stop, depth) do
    case :binary.at(masked, index) do
      ?, when depth == 0 -> index
      ?( -> separator(masked, index + 1, stop, depth + 1)
      ?) when depth == 0 -> nil
      ?) -> separator(masked, index + 1, stop, depth - 1)
      _char -> separator(masked, index + 1, stop, depth)
    end
  end

  defp brace_end(_masked, index, stop, _depth) when index >= stop, do: nil

  defp brace_end(masked, index, stop, depth) do
    case :binary.at(masked, index) do
      ?{ -> brace_end(masked, index + 1, stop, depth + 1)
      ?} when depth == 1 -> index
      ?} -> brace_end(masked, index + 1, stop, depth - 1)
      _char -> brace_end(masked, index + 1, stop, depth)
    end
  end

  defp scan_options(
         _source,
         _strings,
         _masked,
         index,
         stop,
         _braces,
         _parens,
         _brackets,
         goal,
         credentials
       )
       when index >= stop do
    {goal, credentials}
  end

  defp scan_options(
         source,
         strings,
         masked,
         index,
         stop,
         braces,
         parens,
         brackets,
         goal,
         credentials
       ) do
    case :binary.at(masked, index) do
      ?{ ->
        scan_options(
          source,
          strings,
          masked,
          index + 1,
          stop,
          braces + 1,
          parens,
          brackets,
          goal,
          credentials
        )

      ?} ->
        scan_options(
          source,
          strings,
          masked,
          index + 1,
          stop,
          braces - 1,
          parens,
          brackets,
          goal,
          credentials
        )

      ?( ->
        scan_options(
          source,
          strings,
          masked,
          index + 1,
          stop,
          braces,
          parens + 1,
          brackets,
          goal,
          credentials
        )

      ?) ->
        scan_options(
          source,
          strings,
          masked,
          index + 1,
          stop,
          braces,
          parens - 1,
          brackets,
          goal,
          credentials
        )

      ?[ ->
        scan_options(
          source,
          strings,
          masked,
          index + 1,
          stop,
          braces,
          parens,
          brackets + 1,
          goal,
          credentials
        )

      ?] ->
        scan_options(
          source,
          strings,
          masked,
          index + 1,
          stop,
          braces,
          parens,
          brackets - 1,
          goal,
          credentials
        )

      _char ->
        advance_options(
          source,
          strings,
          masked,
          index,
          stop,
          braces,
          parens,
          brackets,
          goal,
          credentials
        )
    end
  end

  defp advance_options(
         source,
         strings,
         masked,
         index,
         stop,
         braces,
         parens,
         brackets,
         goal,
         credentials
       ) do
    cond do
      option_level?(braces, parens, brackets) and
          option_key?(source, masked, strings, index, "type") ->
        apply_type(
          source,
          strings,
          masked,
          index,
          stop,
          braces,
          parens,
          brackets,
          goal,
          credentials
        )

      option_level?(braces, parens, brackets) and
          option_key?(source, masked, strings, index, "credentials") ->
        apply_credentials(
          source,
          strings,
          masked,
          index,
          stop,
          braces,
          parens,
          brackets,
          goal,
          credentials
        )

      true ->
        scan_options(
          source,
          strings,
          masked,
          index + 1,
          stop,
          braces,
          parens,
          brackets,
          goal,
          credentials
        )
    end
  end

  defp option_level?(braces, parens, brackets) do
    braces == 1 and parens == 0 and brackets == 0
  end

  defp apply_type(
         source,
         strings,
         masked,
         index,
         stop,
         braces,
         parens,
         brackets,
         goal,
         credentials
       ) do
    case option_value(source, strings, masked, index + 4, stop) do
      {:ok, text, next} ->
        scan_options(
          source,
          strings,
          masked,
          next,
          stop,
          braces,
          parens,
          brackets,
          script_goal(text),
          credentials
        )

      :no ->
        scan_options(
          source,
          strings,
          masked,
          index + 1,
          stop,
          braces,
          parens,
          brackets,
          goal,
          credentials
        )
    end
  end

  defp apply_credentials(
         source,
         strings,
         masked,
         index,
         stop,
         braces,
         parens,
         brackets,
         goal,
         credentials
       ) do
    case option_value(source, strings, masked, index + 11, stop) do
      {:ok, text, next} ->
        scan_options(
          source,
          strings,
          masked,
          next,
          stop,
          braces,
          parens,
          brackets,
          goal,
          worker_credential(text)
        )

      :no ->
        scan_options(
          source,
          strings,
          masked,
          index + 1,
          stop,
          braces,
          parens,
          brackets,
          goal,
          credentials
        )
    end
  end

  defp option_key?(source, masked, strings, index, name) do
    size = byte_size(name)

    index + size <= byte_size(source) and binary_part(source, index, size) == name and
      (masked_key?(masked, index, size) or MapSet.member?(strings, {index, index + size}))
  end

  defp masked_key?(masked, index, size) do
    next = index + size

    binary_part(masked, index, size) == String.duplicate("_", size) and
      identifier_boundary?(masked, index) and
      (next >= byte_size(masked) or :binary.at(masked, next) != ?_)
  end

  defp option_value(source, strings, masked, index, stop) do
    index =
      if index < stop and :binary.at(masked, index) in [?", ?', ?`], do: index + 1, else: index

    index = skip(masked, index, stop)

    if index < stop and :binary.at(masked, index) == ?: do
      read_option(source, strings, masked, skip(masked, index + 1, stop), stop)
    else
      :no
    end
  end

  defp read_option(source, strings, masked, value_at, stop) do
    if value_at < stop and :binary.at(source, value_at) in [?", ?', ?`] do
      decoded_literal(source, strings, masked, value_at, stop)
    else
      :no
    end
  end

  defp decoded_literal(source, strings, masked, quote_at, stop) do
    mark = :binary.at(source, quote_at)
    at = quote_at + 1

    with true <- at < stop,
         {len, _} <- :binary.match(binary_part(masked, at, stop - at), <<mark>>),
         true <- MapSet.member?(strings, {at, at + len}),
         {:ok, text} <- StringLiteral.decode(binary_part(source, at, len)),
         true <- type_literal?(masked, at + len + 1, stop) do
      {:ok, text, at + len + 1}
    else
      _ -> :no
    end
  end

  defp script_goal("module"), do: :module
  defp script_goal(_text), do: :script

  defp worker_credential("include"), do: :include
  defp worker_credential("omit"), do: :omit
  defp worker_credential("same-origin"), do: :same_origin
  defp worker_credential(_text), do: :same_origin

  # `stop` is the options object's closing brace, which the scan does not enter.
  defp type_literal?(masked, index, stop) do
    index = skip(masked, index, stop + 1)

    index == stop or (index < stop and :binary.at(masked, index) == ?,)
  end

  defp call?(masked, strings, whole, paren) do
    at = index(whole)

    :binary.at(masked, index(paren)) == ?( and not inside_string?(strings, at) and
      identifier_boundary?(masked, at)
  end

  defp identifier_boundary?(_masked, 0), do: true
  defp identifier_boundary?(masked, at), do: :binary.at(masked, at - 1) != ?_

  defp inside_string?(strings, at) do
    Enum.any?(strings, fn {start, stop} -> at >= start and at < stop end)
  end

  defp scan(regex, source, fun, state) do
    {:ok, {matches, state}} =
      Matches.reduce(regex, source, {[], state}, fn groups, {acc, state} ->
        state = count(state)

        {matches, state} =
          if is_function(fun, 2), do: fun.(groups, state), else: {fun.(groups), state}

        matches =
          case matches do
            nil -> []
            matches when is_list(matches) -> matches
            match -> [match]
          end

        {budget, retained} = state

        {acc, retained} =
          Enum.reduce(matches, {acc, retained}, fn match, {acc, bytes} ->
            {[match | acc], bytes + call_bytes(match)}
          end)

        {:cont, {acc, {budget, retained}}}
      end)

    {Enum.reverse(matches), state}
  end

  defp count({budget, retained}) do
    case Budget.count(budget, :facts) do
      {:ok, budget} -> {budget, retained}
      error -> throw({:js_calls_budget, error})
    end
  end

  defp call_bytes(call),
    do:
      Budget.cost(:token) + Budget.cost(:binary) +
        Budget.cost(:list_cell, 4) + byte_size(elem(call, 3))

  defp reject_overlaps(matches, {budget, retained}) do
    {kept, _seen, retained} =
      Enum.reduce(matches, {[], MapSet.new(), retained}, fn {:worker, at, len, _, _, _, _} = match,
                                                            {kept, seen, retained} ->
        if MapSet.member?(seen, {at, len}),
          do: {kept, seen, retained - call_bytes(match)},
          else: {[match | kept], MapSet.put(seen, {at, len}), retained}
      end)

    {Enum.reverse(kept), {budget, retained}}
  end

  defp call_end(masked, open), do: scan_end(masked, open + 1, 1)

  defp scan_end(masked, index, _depth) when index >= byte_size(masked), do: :error

  defp scan_end(masked, index, depth) do
    case :binary.at(masked, index) do
      ?( -> scan_end(masked, index + 1, depth + 1)
      ?) when depth == 1 -> {:ok, index}
      ?) -> scan_end(masked, index + 1, depth - 1)
      _char -> scan_end(masked, index + 1, depth)
    end
  end

  defp skip(masked, index, stop) when index < stop do
    if :binary.at(masked, index) in [?\s, ?\t, ?\n, ?\r, ?\f],
      do: skip(masked, index + 1, stop),
      else: index
  end

  defp skip(_masked, index, _stop), do: index

  defp skip_argument(masked, index, stop), do: skip_argument(masked, index, stop, 0)

  defp skip_argument(_masked, index, stop, _depth) when index >= stop, do: stop

  defp skip_argument(masked, index, stop, depth) do
    case :binary.at(masked, index) do
      ?, when depth == 0 ->
        index

      open when open in [?(, ?[, ?{] ->
        skip_argument(masked, index + 1, stop, depth + 1)

      ?) when depth == 0 ->
        index

      close when close in [?), ?], ?}] and depth > 0 ->
        skip_argument(masked, index + 1, stop, depth - 1)

      _char ->
        skip_argument(masked, index + 1, stop, depth)
    end
  end

  defp index({at, _len}), do: at
end
