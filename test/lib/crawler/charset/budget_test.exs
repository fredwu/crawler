defmodule Crawler.Charset.BudgetTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis.Budget
  alias Crawler.Charset
  alias Crawler.Charset.Encoding

  defp budget(bytes \\ 2_000_000) do
    Budget.new(%{
      max_total_bytes: bytes,
      max_facts: 100_000,
      max_regions: 10,
      max_occurrences: 100,
      max_edits: 100
    })
  end

  test "owned result preserves canonical branch provenance and the existing ledger" do
    inputs = [
      {:binary.copy("aé", 100), %{content_type: "text/plain"}, :borrowed},
      {<<0xEF, 0xBB, 0xBF>> <> :binary.copy("x", 1_024), %{content_type: "text/plain"},
       :borrowed},
      {:binary.copy(<<0xE9>>, 100),
       %{content_type: "text/plain", headers: [{"content-type", "text/plain; charset=latin1"}]},
       :retained},
      {~s(<meta charset="latin1">abc), %{content_type: "text/html"}, :retained},
      {<<0xFF, 0xFE>> <> :unicode.characters_to_binary("<svg/>", :utf8, {:utf16, :little}),
       %{content_type: "image/svg+xml"}, :retained}
    ]

    for {input, opts, expected} <- inputs do
      assert {:ok, decoded, ledger, ^expected} =
               Charset.decode_owned_result(input, opts, budget())

      assert {:ok, ^decoded, ^ledger} = Charset.decode_result(input, opts, budget())
      assert ledger.scratch == 0

      if expected == :retained,
        do:
          assert(ledger.retained >= :binary.referenced_byte_size(decoded) + Budget.cost(:binary))
    end
  end

  test "converted and declaration roots fund their full physical backing" do
    for count <- [1, 5, 100, 255, 256, 1_024] do
      for {input, type, charset} <- [
            {:binary.copy(<<0xE9>>, count), "text/plain", "latin1"},
            {~s(<meta charset="latin1">) <> :binary.copy("a", count), "text/html", "utf-8"},
            {~s(@charset "latin1";) <> :binary.copy("a", count), "text/css", "utf-8"},
            {~s(<?xml version="1.0" encoding="latin1"?><svg>) <>
               :binary.copy("a", count) <> "</svg>", "application/xml", "utf-8"}
          ] do
        opts = %{content_type: type, headers: [{"content-type", type <> "; charset=" <> charset}]}

        assert {:ok, decoded, ledger, :retained} =
                 Charset.decode_owned_result(input, opts, budget())

        assert ledger.retained >= :binary.referenced_byte_size(decoded) + Budget.cost(:binary),
               "#{type} count=#{count} logical=#{byte_size(decoded)} backing=#{:binary.referenced_byte_size(decoded)} charged=#{ledger.retained}"

        assert ledger.scratch == 0
      end
    end
  end

  test "small BOM root provenance follows its known extraction branch" do
    input = <<0xEF, 0xBB, 0xBF>> <> "abc"

    assert {:ok, "abc" = decoded, ledger, ownership} =
             Charset.decode_owned_result(input, %{content_type: "text/plain"}, budget())

    expected =
      if :binary.referenced_byte_size(decoded) > byte_size(decoded),
        do: :borrowed,
        else: :retained

    assert ownership == expected
    assert ledger.retained == Budget.cost(:binary) + if(expected == :retained, do: 3, else: 0)
  end

  test "valid UTF8 near max_body returns the original physical root without a body reservation" do
    body = :binary.copy("aé😀", 100_000)
    opts = %{content_type: "text/plain", max_body: byte_size(body)}
    assert {:ok, decoded, ledger} = Charset.decode_result(body, opts, budget(2_048))
    assert :erts_debug.same(decoded, body)
    assert ledger.retained == 0
    assert ledger.scratch == 0
    assert ledger.peak < 2_048
  end

  test "unchanged HTML near max_body streams canonical tags and reuses the input backing" do
    body =
      "<html><head><meta charset=\"utf-8\"></head><body>" <>
        :binary.copy("a", 1_000_000) <> "</body></html>"

    opts = %{content_type: "text/html", max_body: byte_size(body)}
    assert {:ok, decoded, ledger} = Charset.decode_result(body, opts, budget(700_000))
    assert :erts_debug.same(decoded, body)
    assert ledger.retained == 0
    assert ledger.scratch == 0
    assert ledger.peak < byte_size(body)
  end

  test "nontext and undeclared text XML retain the borrowed bytes" do
    body = :binary.copy(<<0xE9, 0xFF>>, 100)

    for {type, capacity} <- [{"image/png", 2_048}, {"text/xml", 131_072}] do
      assert {:ok, decoded, ledger} =
               Charset.decode_result(body, %{content_type: type}, budget(capacity))

      assert :erts_debug.same(decoded, body)
      assert ledger.retained == 0
      assert ledger.scratch == 0
    end

    assert Charset.decode_result(body, %{content_type: "text/xml"}, budget(2_048)) ==
             {:error, {:limit, :analysis_bytes}}

    assert Charset.decode_result(nil, %{}, budget(0)) == {:ok, nil, budget(0)}
  end

  test "BOM slicing records borrowed view headers rather than a second large body" do
    input = <<0xEF, 0xBB, 0xBF>> <> :binary.copy("x", 1_024)

    assert {:ok, decoded, ledger} =
             Charset.decode_result(input, %{content_type: "text/plain"}, budget(2_048))

    assert decoded == :binary.copy("x", 1_024)
    assert :binary.referenced_byte_size(decoded) == byte_size(input)
    assert ledger.retained == Budget.cost(:binary)
    assert ledger.scratch == 0
  end

  test "small BOM slices keep authority for copied bytes" do
    input = <<0xEF, 0xBB, 0xBF>> <> "abc"

    assert {:ok, "abc" = decoded, ledger} =
             Charset.decode_result(input, %{content_type: "text/plain"}, budget(2_048))

    if :binary.referenced_byte_size(decoded) == byte_size(decoded) do
      assert ledger.retained == Budget.cost(:binary) + 3
    else
      assert ledger.retained == Budget.cost(:binary)
    end
  end

  test "new transcoded root is charged once and temporary chunks are released" do
    input = :binary.copy(<<0xE9>>, 600)

    opts = %{
      content_type: "text/plain",
      headers: [{"content-type", "text/plain; charset=latin1"}],
      max_body: 1_200
    }

    assert {:ok, decoded, ledger} = Charset.decode_result(input, opts, budget())
    assert decoded == :binary.copy("é", 600)
    assert ledger.retained == Budget.cost(:binary) + byte_size(decoded)
    assert ledger.scratch == 0
    assert ledger.peak > ledger.retained
    refute :erts_debug.same(input, decoded)

    assert Charset.decode_result(input, %{opts | max_body: 1_199}, budget()) ==
             {:error, {:limit, :max_body}}
  end

  test "invalid UTF8 replacement uses bounded chunks rather than retaining one record per byte" do
    input = :binary.copy(<<0xFF>>, 8_192)

    assert {:ok, decoded, ledger} =
             Charset.decode_result(input, %{content_type: "text/plain"}, budget(200_000))

    assert decoded == :binary.copy("�", 8_192)
    assert ledger.retained == byte_size(decoded) + Budget.cost(:binary)
    assert ledger.scratch == 0
    assert ledger.peak < 200_000
  end

  test "UTF16 conversion and declaration normalization keep candidate and final root overlap charged" do
    xml = ~s(<?xml version="1.0" encoding="UTF-16"?><svg><text>café😀</text></svg>)

    for {bom, endian} <- [{<<0xFF, 0xFE>>, :little}, {<<0xFE, 0xFF>>, :big}] do
      input = bom <> :unicode.characters_to_binary(xml, :utf8, {:utf16, endian})

      assert {:ok, decoded, ledger} =
               Charset.decode_result(input, %{content_type: "image/svg+xml"}, budget())

      assert decoded == String.replace(xml, "UTF-16", "utf-8")
      assert ledger.retained == byte_size(decoded) + Budget.cost(:binary)
      assert ledger.scratch == 0
      assert ledger.peak > ledger.retained + byte_size(xml)

      assert Charset.decode_result(
               input,
               %{content_type: "image/svg+xml"},
               budget(ledger.peak - 1)
             ) ==
               {:error, {:limit, :analysis_bytes}}
    end
  end

  test "header and declaration candidates use residual upstream authority" do
    {:ok, upstream} = Budget.charge(budget(), 4_096, facts: 2)
    {:ok, upstream} = Budget.reserve(upstream, 2_048)
    input = ~s(<meta charset="latin1">caf) <> <<0xE9>>

    assert {:ok, decoded, ledger} =
             Charset.decode_result(input, %{content_type: "text/html"}, upstream)

    assert decoded == ~s(<meta charset="utf-8">café)
    assert ledger.retained == upstream.retained + byte_size(decoded) + Budget.cost(:binary)
    assert ledger.scratch == upstream.scratch
    assert ledger.counts.facts > upstream.counts.facts
  end

  test "declaration copies cannot escape the shared byte allowance" do
    input = ~s(<meta charset="latin1">) <> :binary.copy("x", 1_000)
    opts = %{content_type: "text/html", headers: [{"content-type", "text/html; charset=utf-8"}]}
    assert {:ok, decoded, ledger} = Charset.decode_result(input, opts, budget())
    assert decoded == ~s(<meta charset="utf-8">) <> :binary.copy("x", 1_000)
    assert ledger.retained == byte_size(decoded) + Budget.cost(:binary)

    assert Charset.decode_result(input, opts, budget(ledger.peak - 1)) ==
             {:error, {:limit, :analysis_bytes}}
  end

  test "canonical CSS declarations already in UTF8 retain the input root" do
    input = ~s(@charset "utf-8";) <> :binary.copy("a", 8_000)

    assert {:ok, decoded, ledger} =
             Charset.decode_result(input, %{content_type: "text/css"}, budget())

    assert :erts_debug.same(input, decoded)
    assert ledger.retained == 0
    assert ledger.scratch == 0
  end

  test "all result roots obey managed max_body without changing native unlimited behavior" do
    for {input, type} <- [
          {"abc", "text/plain"},
          {"abc", "image/png"},
          {"<svg/>", "image/svg+xml"}
        ] do
      assert Charset.decode_result(input, %{content_type: type, max_body: 0}, budget()) ==
               {:error, {:limit, :max_body}}

      assert Charset.decode(input, %{content_type: type, max_body: 0}) == input
    end

    assert Charset.decode_result("", %{content_type: "image/svg+xml", max_body: 0}, budget(0)) ==
             {:ok, "", budget(0)}
  end

  test "conversion fails before Unicode when scratch is not available" do
    {result, calls} =
      traced({:unicode, :characters_to_binary, 3}, fn ->
        Charset.decode_result(<<0xFF>>, %{content_type: "text/plain"}, budget(700))
      end)

    assert result == {:error, {:limit, :analysis_bytes}}
    assert calls == []
  end

  test "UTF8 and UTF16 chunks preserve partial multibyte and surrogate boundaries" do
    for prefix <- [253, 254, 255, 256] do
      text = :binary.copy("a", prefix) <> "😀é" <> "�z"
      invalid = text <> <<0xFF>>
      assert {:ok, decoded, _budget, _owned} = Encoding.decode_result(invalid, :utf8, budget())
      assert decoded == text <> "�"

      for endian <- [:little, :big] do
        encoded = :unicode.characters_to_binary(text, :utf8, {:utf16, endian})

        assert {:ok, ^text, _budget, _owned} =
                 Encoding.decode_result(encoded, {:utf16, endian}, budget())
      end
    end
  end

  test "max_body applies after a converted candidate shrinks during declaration rewrite" do
    xml = ~s(<?xml version="1.0" encoding="UTF-16"?><svg>é😀</svg>)
    expected = String.replace(xml, "UTF-16", "utf-8")
    assert byte_size(xml) == byte_size(expected) + 1

    for {bom, endian} <- [{<<0xFF, 0xFE>>, :little}, {<<0xFE, 0xFF>>, :big}] do
      input = bom <> :unicode.characters_to_binary(xml, :utf8, {:utf16, endian})
      opts = %{content_type: "image/svg+xml", max_body: byte_size(expected)}
      assert {:ok, ^expected, ledger} = Charset.decode_result(input, opts, budget())
      assert ledger.retained == Budget.cost(:binary) + byte_size(expected)
      assert ledger.scratch == 0

      assert Charset.decode_result(input, %{opts | max_body: byte_size(expected) - 1}, budget()) ==
               {:error, {:limit, :max_body}}
    end
  end

  test "an over-cap candidate still requires full shared analysis authority" do
    xml = ~s(<?xml version="1.0" encoding="UTF-16"?><svg>) <> :binary.copy("é", 1_000) <> "</svg>"
    expected = String.replace(xml, "UTF-16", "utf-8")
    input = <<0xFF, 0xFE>> <> :unicode.characters_to_binary(xml, :utf8, {:utf16, :little})
    opts = %{content_type: "image/svg+xml", max_body: byte_size(expected)}

    assert Charset.decode_result(input, opts, budget(byte_size(xml) - 1)) ==
             {:error, {:limit, :analysis_bytes}}

    assert {:ok, ^expected, _ledger} = Charset.decode_result(input, opts, budget())
  end

  test "only the exact final HTML size is capped across multiple declaration edits" do
    input = ~s(<meta charset=""><meta charset="abcdefghijklmnop">)
    expected = ~s(<meta charset="utf-8"><meta charset="utf-8">)
    assert byte_size(expected) < byte_size(input)

    assert {:ok, ^expected, ledger} =
             Charset.decode_result(
               input,
               %{content_type: "text/html", max_body: byte_size(input)},
               budget()
             )

    assert ledger.retained == byte_size(expected) + Budget.cost(:binary)
    assert ledger.scratch == 0
  end

  test "large header parameter lists fail before materialization" do
    header = "text/plain;" <> :binary.copy(" x=1;", 128)

    {result, calls} =
      traced({Crawler.Charset.Parameters, :values, 1}, fn ->
        Charset.decode_result(
          "x",
          %{content_type: "text/plain", headers: [{"content-type", header}]},
          budget(4_096)
        )
      end)

    assert result == {:error, {:limit, :analysis_bytes}}
    assert calls == []
  end

  test "all declaration buffers are prepaid before canonical attribute parsing" do
    input = ~s(<meta data=") <> :binary.copy("a", 2_048) <> ~s(" charset="latin1">)

    {result, calls} =
      traced({Crawler.Charset.HTMLScanner, :attributes, 1}, fn ->
        Charset.decode_result(
          input,
          %{content_type: "text/html", headers: [{"content-type", "text/html; charset=utf-8"}]},
          budget(200_000)
        )
      end)

    assert result == {:error, {:limit, :analysis_bytes}}
    assert calls == []
  end

  test "invalid managed output caps stay distinct from resource exhaustion" do
    for cap <- [-1, false, "100"] do
      assert Charset.decode_result("x", %{content_type: "text/plain", max_body: cap}, budget()) ==
               {:error, :invalid_limits}
    end
  end

  test "the converted candidate stays charged when the final XML root is allocated" do
    candidate = ~s(<?xml version="1.0" encoding="UTF-16"?><svg>é</svg>)
    expected = String.replace(candidate, "UTF-16", "utf-8")
    input = <<0xFF, 0xFE>> <> :unicode.characters_to_binary(candidate, :utf8, {:utf16, :little})

    encoded = :unicode.characters_to_binary(candidate, :utf8, {:utf16, :little})

    assert {:ok, ^candidate, _candidate_budget, candidate_owned} =
             Encoding.decode_result(encoded, {:utf16, :little}, budget())

    {result, calls} =
      traced({Budget, :charge, 3}, fn ->
        Charset.decode_result(input, %{content_type: "image/svg+xml"}, budget())
      end)

    assert {:ok, ^expected, _ledger} = result

    assert Enum.any?(calls, fn
             {Budget, :charge, [ledger, bytes, []]} ->
               bytes == Budget.cost(:binary) + byte_size(expected) and
                 ledger.retained == candidate_owned and
                 ledger.scratch > 0

             _ ->
               false
           end)
  end

  defp traced(mfa, fun) do
    parent = self()

    pid =
      spawn(fn ->
        receive do
          :go ->
            send(parent, {:result, self(), fun.()})
            receive do: (:finish -> :ok)
        end
      end)

    :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(pid, true, [:call])
    send(pid, :go)

    try do
      assert_receive {:result, ^pid, result}, 5_000
      ref = :erlang.trace_delivered(pid)
      assert_receive {:trace_delivered, ^pid, ^ref}, 5_000
      {result, trace_calls(pid, [])}
    after
      :erlang.trace_pattern(mfa, false, [:local])
      send(pid, :finish)
    end
  end

  defp trace_calls(pid, acc) do
    receive do
      {:trace, ^pid, :call, call} -> trace_calls(pid, [call | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
