defmodule Crawler.Parser.JsParser.Calls do
  @moduledoc false

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
  @import_scripts Regex.compile!("(?<![\\w$.])importScripts#{@gap}*(\\()")

  # The scanner keeps `import` visible and masks every other identifier, so
  # these calls are matched on the original source. Paren depth still uses the
  # mask, where string and comment contents are spaces.
  def spans(source, goal) when is_binary(source) and goal in [:script, :module] do
    {masked, strings} = Scanner.scan(source, goal)
    strings = MapSet.new(strings)
    workers = workers(source, masked, strings, goal)
    taken = MapSet.new(for {:worker, at, len, _spec, _goal, :module} <- workers, do: {at, len})

    urls =
      if goal == :module do
        source
        |> urls(masked, strings)
        |> Enum.reject(fn {:url, at, len, _spec} -> MapSet.member?(taken, {at, len}) end)
      else
        []
      end

    workers ++ urls ++ import_scripts(source, masked, strings)
  end

  def spans(_source, _goal), do: []

  defp workers(source, masked, strings, goal) do
    meta = if goal == :module, do: worker_urls(source, masked, strings), else: []
    meta ++ worker_strings(source, masked, strings) ++ registers(source, masked, strings)
  end

  defp worker_urls(source, masked, strings) do
    reject_overlaps(
      scan(@worker, source, fn [whole, _kind, paren] ->
        open = index(paren)

        with true <- call?(masked, strings, whole, paren),
             {:ok, url_open} <- worker_url_open(source, masked, open),
             {:ok, {at, len, text}, next} <- first_string(masked, source, strings, url_open),
             {:ok, url_close} <- meta_base_end(source, next),
             true <- literal_argument?(masked, {url_close, 0}),
             {:ok, close} <- call_end(masked, open) do
          {:worker, at, len, text, worker_goal(source, strings, masked, open, close), :module}
        else
          _ -> nil
        end
      end)
    )
  end

  defp worker_strings(source, masked, strings) do
    scan(@worker, source, fn [whole, _kind, paren] ->
      open = index(paren)

      with true <- call?(masked, strings, whole, paren),
           {:ok, {at, len, text}, _next} <- first_string(masked, source, strings, open),
           true <- literal_argument?(masked, {at, len}),
           {:ok, close} <- call_end(masked, open) do
        {:worker, at, len, text, worker_goal(source, strings, masked, open, close), :window}
      else
        _ -> nil
      end
    end)
  end

  defp registers(source, masked, strings) do
    scan(@register, source, fn [whole, paren] ->
      open = index(paren)

      with true <- call?(masked, strings, whole, paren),
           {:ok, {at, len, text}, _next} <- first_string(masked, source, strings, open),
           true <- literal_argument?(masked, {at, len}),
           {:ok, close} <- call_end(masked, open) do
        {:worker, at, len, text, worker_goal(source, strings, masked, open, close), :window}
      else
        _ -> nil
      end
    end)
  end

  defp urls(source, masked, strings) do
    scan(@meta_url, source, fn [whole, paren] ->
      with true <- call?(masked, strings, whole, paren),
           {:ok, {at, len, text}, next} <- first_string(masked, source, strings, index(paren)),
           {:ok, _close} <- meta_base_end(source, next) do
        {:url, at, len, text}
      else
        _ -> nil
      end
    end)
  end

  defp import_scripts(source, masked, strings) do
    List.flatten(scan(@import_scripts, source, &script_call(&1, source, masked, strings)))
  end

  defp script_call([whole, paren], source, masked, strings) do
    if call?(masked, strings, whole, paren) do
      script_arguments(source, masked, strings, paren)
    else
      []
    end
  end

  defp script_arguments(source, masked, strings, paren) do
    case call_end(masked, index(paren)) do
      {:ok, close} -> arguments(masked, source, strings, index(paren) + 1, close)
      :error -> []
    end
  end

  defp arguments(masked, source, strings, index, stop) do
    index = skip(masked, index, stop)

    cond do
      index >= stop ->
        []

      :binary.at(masked, index) == ?, ->
        arguments(masked, source, strings, index + 1, stop)

      :binary.at(masked, index) in [?", ?', ?`] ->
        string_argument(masked, source, strings, index, stop)

      true ->
        arguments(masked, source, strings, skip_argument(masked, index, stop), stop)
    end
  end

  defp string_argument(masked, source, strings, index, stop) do
    case one_string(masked, source, strings, index, stop) do
      {:ok, {at, len, text}, next} ->
        literal_scripts(masked, source, strings, at, len, text, next, stop)

      {:skip, next} ->
        arguments(masked, source, strings, next, stop)

      :error ->
        []
    end
  end

  defp literal_scripts(masked, source, strings, at, len, text, next, stop) do
    if literal_argument?(masked, {at, len}) do
      [{:scripts, at, len, text} | arguments(masked, source, strings, next, stop)]
    else
      arguments(masked, source, strings, skip_argument(masked, next, stop), stop)
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
    index = skip(masked, open + 1, byte_size(masked))
    rest = binary_part(source, index, byte_size(source) - index)

    case Regex.run(@worker_url_open, rest, return: :index) do
      [{0, len}] ->
        paren = index + len - 1
        if :binary.at(masked, paren) == ?(, do: {:ok, paren}, else: :error

      _ ->
        :error
    end
  end

  defp meta_base_end(source, index) do
    rest = binary_part(source, index, byte_size(source) - index)

    case Regex.run(@meta_base, rest, return: :index) do
      [{0, len}] -> {:ok, index + len - 1}
      _ -> :error
    end
  end

  defp literal_argument?(masked, {at, len}) do
    index = skip(masked, at + len + 1, byte_size(masked))
    index < byte_size(masked) and :binary.at(masked, index) in [?,, ?)]
  end

  defp worker_goal(source, strings, masked, open, close) do
    case options_brace(masked, open, close) do
      {start, stop} ->
        scan_type(source, strings, masked, start + 1, stop, 1, 0, 0, :script)

      nil ->
        :script
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

  defp scan_type(_source, _strings, _masked, index, stop, _braces, _parens, _brackets, goal)
       when index >= stop do
    goal
  end

  defp scan_type(source, strings, masked, index, stop, braces, parens, brackets, goal) do
    case :binary.at(masked, index) do
      ?{ ->
        scan_type(source, strings, masked, index + 1, stop, braces + 1, parens, brackets, goal)

      ?} ->
        scan_type(source, strings, masked, index + 1, stop, braces - 1, parens, brackets, goal)

      ?( ->
        scan_type(source, strings, masked, index + 1, stop, braces, parens + 1, brackets, goal)

      ?) ->
        scan_type(source, strings, masked, index + 1, stop, braces, parens - 1, brackets, goal)

      ?[ ->
        scan_type(source, strings, masked, index + 1, stop, braces, parens, brackets + 1, goal)

      ?] ->
        scan_type(source, strings, masked, index + 1, stop, braces, parens, brackets - 1, goal)

      _char ->
        advance_type(source, strings, masked, index, stop, braces, parens, brackets, goal)
    end
  end

  defp advance_type(source, strings, masked, index, stop, braces, parens, brackets, goal) do
    if braces == 1 and parens == 0 and brackets == 0 and type_key?(source, masked, strings, index) do
      apply_type(source, strings, masked, index, stop, braces, parens, brackets, goal)
    else
      scan_type(source, strings, masked, index + 1, stop, braces, parens, brackets, goal)
    end
  end

  defp apply_type(source, strings, masked, index, stop, braces, parens, brackets, goal) do
    case type_value(source, strings, masked, index + 4, stop) do
      {:ok, next, next_goal} ->
        scan_type(source, strings, masked, next, stop, braces, parens, brackets, next_goal)

      :no ->
        scan_type(source, strings, masked, index + 1, stop, braces, parens, brackets, goal)
    end
  end

  defp type_key?(source, masked, strings, index) do
    index + 4 <= byte_size(source) and binary_part(source, index, 4) == "type" and
      (identifier_key?(masked, index) or MapSet.member?(strings, {index, index + 4}))
  end

  defp identifier_key?(masked, index) do
    next = index + 4

    binary_part(masked, index, 4) == "____" and identifier_boundary?(masked, index) and
      (next >= byte_size(masked) or :binary.at(masked, next) != ?_)
  end

  defp type_value(source, strings, masked, index, stop) do
    index =
      if index < stop and :binary.at(masked, index) in [?", ?', ?`], do: index + 1, else: index

    index = skip(masked, index, stop)

    if index < stop and :binary.at(masked, index) == ?: do
      value_at = skip(masked, index + 1, stop)

      if value_at < stop and :binary.at(source, value_at) in [?", ?', ?`] do
        decode_type(source, strings, masked, value_at, stop)
      else
        :no
      end
    else
      :no
    end
  end

  defp decode_type(source, strings, masked, quote_at, stop) do
    mark = :binary.at(source, quote_at)
    at = quote_at + 1

    with true <- at < stop,
         {len, _} <- :binary.match(binary_part(masked, at, stop - at), <<mark>>),
         true <- MapSet.member?(strings, {at, at + len}),
         {:ok, text} <- StringLiteral.decode(binary_part(source, at, len)),
         true <- type_literal?(masked, at + len + 1, stop) do
      goal = if text == "module", do: :module, else: :script
      {:ok, at + len + 1, goal}
    else
      _ -> :no
    end
  end

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

  defp scan(regex, masked, fun) do
    regex
    |> Regex.scan(masked, return: :index)
    |> Enum.flat_map(fn groups ->
      case fun.(groups) do
        nil -> []
        matches when is_list(matches) -> matches
        match -> [match]
      end
    end)
  end

  defp reject_overlaps(matches) do
    {kept, _} =
      Enum.reduce(matches, {[], MapSet.new()}, fn {:worker, at, len, _, _, _} = match,
                                                  {kept, seen} ->
        if MapSet.member?(seen, {at, len}),
          do: {kept, seen},
          else: {[match | kept], MapSet.put(seen, {at, len})}
      end)

    Enum.reverse(kept)
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
