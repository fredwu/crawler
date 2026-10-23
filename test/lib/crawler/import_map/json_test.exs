defmodule Crawler.ImportMap.JSONTest do
  use ExUnit.Case, async: true

  alias Crawler.ImportMap
  alias Crawler.ImportMap.JSON
  alias Crawler.Parser.SourceMap
  alias Crawler.Parser.SpeculationRules
  alias Crawler.Parser.WebManifest

  test "accepts every JSON escape and valid Unicode scalar" do
    fixtures = [
      {~S("\"\\\/\b\f\n\r\t"), "\"\\/\b\f\n\r\t"},
      {~S("\u0000\u001f\u0020\u007f"), <<0, 31, 32, 127>>},
      {~S("\uD800\uDC00\udbff\udfff"), <<0x10000::utf8, 0x10FFFF::utf8>>},
      {~S("\uFEFF"), "\uFEFF"},
      {~s("é中文😀"), "é中文😀"}
    ]

    for {source, expected} <- fixtures do
      assert JSON.decode(source) == {:ok, expected}
      assert JSON.decode_located(source) == {:ok, {:str, expected, 0, byte_size(source)}}
    end
  end

  test "rejects unknown escapes in keys and values" do
    for escape <- 0..255, escape not in ~c("\\/bfnrtu) do
      string = <<?", ?\\, escape, ?">>
      assert_error(string)
      assert_error("{" <> string <> ":null}")
      assert_error("[" <> string <> "]")
    end

    assert_error(<<?", ?\\, ?">>)
    assert_error(<<?", ?\\>>)
  end

  test "rejects unescaped controls, invalid UTF-8, and incomplete strings" do
    for control <- 0..31 do
      assert_error(<<?", control, ?">>)
    end

    for bytes <- [<<0xFF>>, <<0xC0, 0xAF>>, <<0xED, 0xA0, 0x80>>, <<0xF4, 0x90, 0x80, 0x80>>] do
      assert_error(<<?", bytes::binary, ?">>)
    end

    for source <- ["\"", "\"unfinished", "\"a\"b\"", ~S("\u"), ~S("\u123")] do
      assert_error(source)
    end
  end

  test "rejects malformed Unicode escapes and isolated surrogates" do
    for escape <- [
          "u+123",
          "u-000",
          "u12g4",
          "u12 4",
          "uD800",
          "uDC00",
          "uD800\\uD800",
          "uD800\\u0041",
          "uD800\\q",
          "uD800x\\uDC00",
          "uDC00\\uD800"
        ] do
      assert_error("\"\\" <> escape <> "\"")
    end
  end

  test "retains JSON number types and the overflow sentinel" do
    fixtures = [
      {"0", 0},
      {"-0", 0},
      {"123456789012345678901234567890", 123_456_789_012_345_678_901_234_567_890},
      {"-12.5", -12.5},
      {"1e2", 100.0},
      {"1E-2", 0.01},
      {"1e+2", 100.0},
      {"1e309", :non_finite},
      {"-1e309", :non_finite}
    ]

    for {source, expected} <- fixtures do
      assert JSON.decode(source) === {:ok, expected}
      assert JSON.decode_located(source) === {:ok, expected}
    end

    for source <- ["+1", "01", "-01", ".1", "1.", "1e", "1e+", "--1", "NaN", "Infinity"] do
      assert_error(source)
      assert_error("[" <> source <> "]")
    end
  end

  test "keeps the last duplicate value at the first key position with its final span" do
    source = ~S({"a":"old","b":false,"\u0061":{"x":"before","x":"after"}})

    assert {:ok,
            {:object, [{"a", {:object, [{"x", {:str, "after", start, length}}]}}, {"b", false}]}} =
             JSON.decode_located(source)

    assert binary_part(source, start, length) == ~S("after")

    assert JSON.decode(source) ==
             {:ok, {:object, [{"a", {:object, [{"x", "after"}]}}, {"b", false}]}}
  end

  test "accepts one leading BOM and JSON whitespace with original byte offsets" do
    source = "\uFEFF \t\r\n {\"é\": [ \"😀\", \"\\u0061\" ]} \n"
    assert {:ok, {:object, [{"é", [emoji, escaped]}]}} = JSON.decode_located(source)
    assert {:str, "😀", 17, 6} = emoji
    assert {:str, "a", 25, 8} = escaped
    assert_spans(source, {:object, [{"é", [emoji, escaped]}]})

    for source <- ["\uFEFF\uFEFF{}", " \uFEFF{}", "{}\uFEFF", <<11, ?[, ?]>>, <<12, ?[, ?]>>] do
      assert_error(source)
    end
  end

  test "rejects malformed container syntax and multiple root values" do
    for source <- [
          "",
          " ",
          "{",
          "[",
          "{,}",
          "[, ]",
          "[1,]",
          ~S({"a":1,}),
          ~S({"a" 1}),
          ~S({a:1}),
          ~S({"a":}),
          "[1 2]",
          "true false",
          "nullx",
          "[]{}",
          "/*x*/null"
        ] do
      assert_error(source)
    end

    for input <- [nil, [], %{}, 123] do
      assert_error(input)
    end
  end

  test "plain and located decoding agree for generated nested documents and source spans" do
    fixtures = [
      {"null", nil},
      {"false", false},
      {"true", true},
      {"-12.5", -12.5},
      {~S("a\n😀"), "a\n😀"},
      {~S("\u0061"), "a"},
      {"[]", []},
      {"{}", {:object, []}}
    ]

    for index <- 0..127 do
      {left, left_value} = Enum.at(fixtures, rem(index, length(fixtures)))
      {right, right_value} = Enum.at(fixtures, rem(div(index, 8), length(fixtures)))

      source =
        "\uFEFF {\"a\":" <>
          left <> ",\"b\":[" <> left <> "," <> right <> "],\"\\u0061\":" <> right <> "}"

      expected = {:object, [{"a", right_value}, {"b", [left_value, right_value]}]}

      assert JSON.decode(source) === {:ok, expected}
      assert {:ok, located} = JSON.decode_located(source)
      assert JSON.decode_located_result(source) == {:ok, located}
      assert project(located) === expected
      assert_spans(source, located)
    end
  end

  test "bounds container nesting before recursive parsing or projection" do
    for {open, close} <- [{"[", "]"}, {"{\"x\":", "}"}] do
      accepted = String.duplicate(open, 128) <> "null" <> String.duplicate(close, 128)
      rejected = open <> accepted <> close
      assert {:ok, _value} = JSON.decode(accepted)
      assert {:ok, _value} = JSON.decode_located(accepted)
      assert_error(rejected)
    end
  end

  test "bounds all tokens including duplicate object keys" do
    accepted = "[" <> Enum.join(List.duplicate("0", 99_999), ",") <> "]"
    assert {:ok, values} = JSON.decode(accepted)
    assert length(values) == 99_999
    assert_error("[0," <> binary_part(accepted, 1, byte_size(accepted) - 1))

    duplicates = "{" <> Enum.join(List.duplicate(~S("a":0), 50_000), ",") <> "}"
    assert_error(duplicates)
  end

  test "bounds source bytes, string tokens, and numeric conversion" do
    string = String.duplicate("a", 1_048_576)
    assert JSON.decode("\"" <> string <> "\"") == {:ok, string}
    assert_error("\"a" <> string <> "\"")
    assert_error("{\"a" <> string <> "\":null}")
    assert_error("\"" <> string <> "\\n\"")

    integer = String.duplicate("9", 1_024)
    assert JSON.decode(integer) == {:ok, String.to_integer(integer)}
    assert_error(integer <> "9")
    assert_error("1e" <> integer)

    source = "0" <> String.duplicate(" ", 10_485_759)
    assert JSON.decode(source) == {:ok, 0}
    assert_error(source <> " ")
  end

  test "shared consumers reject malformed URL strings" do
    base = "http://example.com/"
    assert ImportMap.parse(~S({"imports":{"x":"/bad\q.js"}}), base) == :error
    assert WebManifest.entries(~S({"icons":[{"src":"/bad\q.png"}]}), base) == []
    assert SpeculationRules.entries(~S({"prefetch":[{"urls":["/bad\q"]}]}), %{url: base}) == []
    assert SourceMap.entries(~S({"version":3,"sources":["/bad\q.js"]}), %{url: base}) == []
  end

  test "managed decoding identifies grammar errors without changing wrapper results" do
    for source <- [
          nil,
          [],
          1,
          "",
          " ",
          "\uFEFF\uFEFF{}",
          " \uFEFF{}",
          ~S("\q"),
          ~S({"\q":null}),
          ~S("\uD800"),
          <<?", 0xFF, ?">>,
          "[1,]",
          ~S({"a":1,}),
          "[]true",
          "1e",
          "01",
          "1."
        ] do
      assert_managed_error(source, :invalid_json)
    end
  end

  test "managed decoding distinguishes each limit from grammar at its boundary" do
    input = "0" <> String.duplicate(" ", 10_485_759)
    depth = String.duplicate("[", 128) <> "null" <> String.duplicate("]", 128)
    array = "[" <> Enum.join(List.duplicate("0", 99_999), ",") <> "]"
    string = String.duplicate("a", 1_048_576)
    integer = String.duplicate("9", 1_024)

    matrix = [
      {:max_input_bytes, input, input <> " ", "x" <> binary_part(input, 1, byte_size(input) - 1)},
      {:max_depth, depth, "[" <> depth <> "]", String.replace(depth, "null", "?")},
      {:max_tokens, array, "[0," <> binary_part(array, 1, byte_size(array) - 1),
       String.replace_suffix(array, "0]", "?]")},
      {:max_string_bytes, "\"" <> string <> "\"", "\"a" <> string <> "\"",
       "\"" <> binary_part(string, 1, byte_size(string) - 1) <> <<0, ?">>},
      {:max_number_bytes, integer, integer <> "9", String.duplicate("0", 1_024)}
    ]

    for {key, accepted, exceeded, invalid} <- matrix do
      assert {:ok, located} = JSON.decode_located_result(accepted)
      assert JSON.decode_located(accepted) == {:ok, located}
      assert JSON.decode(accepted) == {:ok, project(located)}
      assert_managed_error(exceeded, {:limit, key})
      assert_managed_error(invalid, :invalid_json)
    end
  end

  test "managed limits propagate through object keys, nested values, and escaped strings" do
    string = String.duplicate("a", 1_048_576)

    for source <- [
          "{\"a" <> string <> "\":null}",
          "{\"a\":[\"" <> string <> "\\n\"]}",
          "[\"" <> string <> "\\u0061\"]",
          "[\"" <> string <> "\\uD800\\uDC00\"]"
        ] do
      assert_managed_error(source, {:limit, :max_string_bytes})
    end

    duplicates = "{" <> Enum.join(List.duplicate(~S("a":0), 50_000), ",") <> "}"
    assert_managed_error(duplicates, {:limit, :max_tokens})

    depth = String.duplicate(~S({"a":), 129) <> "null" <> String.duplicate("}", 129)
    assert_managed_error(depth, {:limit, :max_depth})
  end

  test "managed numeric limits count fractions and exponents before conversion" do
    for suffix <- [".0", "e1"] do
      accepted = String.duplicate("9", 1_022) <> suffix
      assert JSON.decode_located_result(accepted) == {:ok, :non_finite}
      assert JSON.decode(accepted) == {:ok, :non_finite}
      assert_managed_error("9" <> accepted, {:limit, :max_number_bytes})
      assert_managed_error("{\"a\":[9" <> accepted <> "]}", {:limit, :max_number_bytes})
    end

    for source <- ["1e309", "-1e309"] do
      assert JSON.decode_located_result(source) == {:ok, :non_finite}
      assert JSON.decode_located(source) == {:ok, :non_finite}
      assert JSON.decode(source) == {:ok, :non_finite}
    end

    for {source, expected} <- [
          {String.duplicate("9", 1_000) <> "e-1000", 1.0},
          {"0." <> String.duplicate("0", 1_021) <> "1", 0.0},
          {"1e-99999999999999999999999", 0.0}
        ] do
      assert JSON.decode_located_result(source) === {:ok, expected}
      assert JSON.decode_located(source) === {:ok, expected}
      assert JSON.decode(source) === {:ok, expected}
    end
  end

  test "managed successes preserve BOM offsets and duplicate key order" do
    source = "\uFEFF " <> ~S({"a":"old","b":false,"\u0061":["é","\u0061"]})

    assert {:ok, {:object, [{"a", [first, second]}, {"b", false}]} = located} =
             JSON.decode_located_result(source)

    assert JSON.decode_located(source) == {:ok, located}
    assert JSON.decode(source) == {:ok, {:object, [{"a", ["é", "a"]}, {"b", false}]}}
    assert_spans(source, first)
    assert_spans(source, second)
    assert {:str, "é", 35, 4} = first
    assert {:str, "a", 40, 8} = second
  end

  test "managed decoding stops at the first exhausted budget without validating the remainder" do
    source = "x" <> String.duplicate(" ", 10_485_760)
    assert_managed_error(source, {:limit, :max_input_bytes})

    source = String.duplicate("[", 129) <> "?"
    assert_managed_error(source, {:limit, :max_depth})
  end

  defp assert_managed_error(input, reason) do
    assert JSON.decode_located_result(input) == {:error, reason}
    assert_error(input)
  end

  defp assert_error(input) do
    assert {:error, _reason} = JSON.decode_located_result(input)
    assert JSON.decode(input) == :error
    assert JSON.decode_located(input) == :error
  end

  defp project({:str, value, _start, _length}), do: value

  defp project({:object, pairs}),
    do: {:object, Enum.map(pairs, fn {key, value} -> {key, project(value)} end)}

  defp project(values) when is_list(values), do: Enum.map(values, &project/1)
  defp project(value), do: value

  defp assert_spans(source, {:str, value, start, length}) do
    assert JSON.decode(binary_part(source, start, length)) == {:ok, value}
  end

  defp assert_spans(source, {:object, pairs}) do
    Enum.each(pairs, fn {_key, value} -> assert_spans(source, value) end)
  end

  defp assert_spans(source, values) when is_list(values),
    do: Enum.each(values, &assert_spans(source, &1))

  defp assert_spans(_source, _value), do: :ok
end
