defmodule Crawler.Sitemap.DocumentTest do
  use ExUnit.Case, async: false
  alias Crawler.Analysis.Budget
  alias Crawler.Deadline
  alias Crawler.Sitemap.Document

  def limits(overrides \\ %{}) do
    Map.merge(
      %{
        max_body: 10_485_760,
        max_control_entries: 50_000,
        max_control_token_bytes: 65_536,
        max_xml_depth: 256,
        max_xml_tokens: 100_000,
        max_xml_attributes: 1_024,
        max_analysis_bytes: 20_000_000
      },
      overrides
    )
  end

  def parse(body, overrides \\ %{}),
    do: Document.parse(body, "https://example.test/maps/root.xml", limits(overrides))

  test "page, image and control roles retain source spans and resolved URLs" do
    body =
      ~s(<sitemapindex><sitemap><loc xml:base="/child/">one.xml</loc></sitemap></sitemapindex>)

    assert {:ok, %{kind: :sitemapindex, entries: [entry]}} = parse(body)
    assert entry.url == "https://example.test/child/one.xml"
    assert entry.role == :control
    assert entry.control_kind == :sitemap
    assert entry.source == %{element: "loc", parent: "sitemap", attribute: nil}
    {at, n} = entry.span
    assert binary_part(body, at, n) == "one.xml"

    body =
      ~s(<urlset><url><loc>/a</loc><image:image><image:loc>cover.jpg</image:loc></image:image></url></urlset>)

    assert {:ok, %{entries: [page, image]}} = parse(body)
    assert page.role == :page
    assert image.role == :image
    assert image.url == "https://example.test/maps/cover.jpg"
  end

  test "prefixed Atom namespaces and incremental bases retain href spans" do
    body =
      ~s(<a:feed xmlns:a="http://www.w3.org/2005/Atom" xml:base="/blog/"><a:entry xml:base="news/"><a:link xml:base="../posts/" href="one?a=1&amp;b=2"/></a:entry></a:feed>)

    assert {:ok, %{kind: :atom, entries: [entry], stats: stats}} = parse(body)
    assert entry.url == "https://example.test/blog/posts/one?a=1&b=2"
    assert entry.source.attribute == "href"
    {at, n} = entry.span
    assert binary_part(body, at, n) == "one?a=1&amp;b=2"
    assert stats.base_resolutions == 3
    assert stats.frames_created == 3
  end

  test "invalid bases preserve the inherited base and siblings restore their parent" do
    body =
      ~s(<feed xml:base="/blog/"><entry xml:base="javascript:bad"><link href="one"/></entry><entry xml:base="https://bad.test:broken/"><link href="two"/></entry><entry><link href="three"/></entry></feed>)

    assert {:ok, %{entries: entries}} = parse(body)

    assert Enum.map(entries, & &1.url) ==
             Enum.map(["one", "two", "three"], &("https://example.test/blog/" <> &1))
  end

  test "deep bases create one frame and one resolution per element" do
    for depth <- [8, 32, 128, 256] do
      body = String.duplicate(~s(<n xml:base="./">), depth) <> String.duplicate("</n>", depth)
      assert {:ok, %{stats: stats}} = parse(body)
      assert stats.frames_created == depth
      assert stats.base_resolutions == depth
      assert stats.max_depth == depth
      assert stats.xml_tokens == 2 * depth
      assert stats.consumed_bytes == byte_size(body)
    end

    body = String.duplicate(~s(<n xml:base="./">), 257) <> String.duplicate("</n>", 257)
    assert {:error, {:limit, :max_xml_depth}} = parse(body)
  end

  test "base growth is bounded before it can accumulate in every frame" do
    body = String.duplicate(~s(<n xml:base="long-path-segment/">), 30)

    assert {:error, {:limit, :max_control_token_bytes}} =
             parse(body, %{max_control_token_bytes: 96})
  end

  test "body, tokens, tags and scalar fields report exact limits" do
    assert {:error, {:limit, :max_body}} = parse("12345", %{max_body: 4})
    assert {:ok, %{stats: %{xml_tokens: 2}}} = parse("<x></x>", %{max_xml_tokens: 2})
    assert {:error, {:limit, :max_xml_tokens}} = parse("<x></x>", %{max_xml_tokens: 1})
    assert {:ok, _} = parse("<loc>12345678</loc>", %{max_control_token_bytes: 8})

    for body <- [
          "<loc>123456789</loc>",
          "<x value='123456789'/>",
          "<!--123456789-->",
          "<description>123456789</description>",
          String.duplicate("x", 9)
        ] do
      assert {:error, {:limit, :max_control_token_bytes}} =
               parse(body, %{max_control_token_bytes: 8})
    end

    huge = "<loc>" <> String.duplicate("a", 1_000_000) <> "</loc>"
    assert {:error, {:limit, :max_control_token_bytes}} = parse(huge)
  end

  test "attributes count before map construction including duplicates" do
    assert {:ok, %{stats: %{max_attributes: 2, attributes: 2}}} =
             parse("<x a='1' b='2'/>", %{max_xml_attributes: 2})

    assert {:error, {:limit, :max_xml_attributes}} =
             parse("<x a='1' a='2' a='3'/>", %{max_xml_attributes: 2})

    huge = "<x " <> String.duplicate("a='x' ", 1_025) <> "/>"
    assert {:error, {:limit, :max_xml_attributes}} = parse(huge)
  end

  test "entries are limited before URL resolution including invalid candidates" do
    entry = "<url><loc>/next</loc></url>"

    assert {:ok, %{entries: entries, stats: %{entries: 3}}} =
             parse("<urlset>" <> String.duplicate(entry, 3) <> "</urlset>", %{
               max_control_entries: 3
             })

    assert length(entries) == 3

    assert {:error, {:limit, :max_control_entries}} =
             parse("<urlset>" <> String.duplicate(entry, 4) <> "</urlset>", %{
               max_control_entries: 3
             })

    bad = String.duplicate("<url><loc>javascript:bad</loc></url>", 4)
    assert {:error, {:limit, :max_control_entries}} = parse(bad, %{max_control_entries: 3})
  end

  test "ignored prose retains depth, token and attribute budgets" do
    assert {:error, {:limit, :max_xml_depth}} =
             parse("<rss><description><a><b><c>x</c></b></a></description></rss>", %{
               max_xml_depth: 4
             })

    assert {:error, {:limit, :max_xml_tokens}} =
             parse("<description><x/><x/><x/></description>", %{max_xml_tokens: 3})

    assert {:error, {:limit, :max_xml_attributes}} =
             parse("<description><x a='1' b='2'/></description>", %{max_xml_attributes: 1})
  end

  test "external declarations are inert and cannot produce entity URLs" do
    body =
      ~s(<!DOCTYPE urlset SYSTEM "http://127.0.0.1:9/dtd" [<!ENTITY x SYSTEM "file:///etc/passwd"><!ENTITY y "https://evil.test/entity">]><urlset><url><loc>&x;</loc></url><url><loc>https://example.test/safe</loc></url></urlset>)

    assert {:ok, %{entries: entries}} = parse(body)
    refute Enum.any?(entries, &String.contains?(&1.url, ["passwd", "evil.test", "127.0.0.1"]))
    assert Enum.any?(entries, &(&1.url == "https://example.test/safe"))
  end

  test "expired absolute attempt and run deadlines return their kind" do
    for kind <- [:attempt, :run] do
      assert {:error, {:deadline, ^kind}} =
               parse("<urlset/>", %{deadline: Deadline.after_ms(0, kind)})
    end

    assert {:ok, _} = parse("<urlset/>", %{deadline: Deadline.after_ms(5_000)})
  end

  test "UTF-16 expansion obeys decoded byte cap and spans use decoded UTF-8" do
    text = "<urlset><url><loc>https://example.test/東京</loc></url></urlset>"
    wire = <<0xFF, 0xFE>> <> :unicode.characters_to_binary(text, :utf8, {:utf16, :little})
    assert {:ok, %{entries: [entry], span_source: :decoded_utf8}} = parse(wire)
    {at, n} = entry.span
    assert binary_part(text, at, n) == "https://example.test/東京"
    latin = ~s(<?xml encoding="Windows-1252"?>) <> "<x>" <> :binary.copy(<<0x99>>, 100) <> "</x>"
    assert {:error, {:limit, :max_body}} = parse(latin, %{max_body: byte_size(latin)})
  end

  test "duplicate attributes retain the first value and matching source span" do
    body = ~s(<feed><entry><link href="one" href="two"/></entry></feed>)
    assert {:ok, %{entries: [entry]}} = parse(body)
    assert entry.raw == "one"
    assert entry.url == "https://example.test/maps/one"
    {at, size} = entry.span
    assert binary_part(body, at, size) == "one"
  end

  test "nested bases at the depth bound resolve an entry and restore outer bases" do
    body =
      ~s(<feed xml:base="/blog/">) <>
        String.duplicate(~s(<n xml:base="./">), 253) <>
        ~s(<entry><link href="one"/></entry>) <>
        String.duplicate("</n>", 253) <>
        ~s(<entry><link href="two"/></entry></feed>)

    assert {:ok, %{entries: entries, stats: stats}} = parse(body)

    assert Enum.map(entries, & &1.url) == [
             "https://example.test/blog/one",
             "https://example.test/blog/two"
           ]

    assert stats.max_depth == 256
    assert stats.base_resolutions == 254
    assert {:error, {:limit, :max_xml_depth}} = parse(body, %{max_xml_depth: 255})
  end

  test "numeric entities cannot allocate arbitrarily large integers" do
    body =
      "<urlset><url><loc>https://example.test/a&#" <>
        String.duplicate("9", 30_000) <> ";b&#0000000000038;c</loc></url></urlset>"

    assert {:ok, %{entries: [entry]}} = parse(body)
    assert entry.url == "https://example.test/ab&c"
  end

  test "a large entry list reaches the aggregate output budget" do
    body = "<urlset>" <> String.duplicate("<url><loc>/a</loc></url>", 50_001) <> "</urlset>"
    assert {:error, {:limit, :max_analysis_bytes}} = parse(body, %{max_xml_tokens: 500_000})
  end

  test "prose scanning checks the shared absolute deadline during scalar work" do
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          :go ->
            body = "<description>" <> String.duplicate("x", 4_096) <> "</description>"
            result = parse(body, %{deadline: Deadline.after_ms(5_000)})
            send(parent, {:finished, self(), result})

            receive do
              :stop -> :ok
            end
        end
      end)

    Code.ensure_loaded!(Deadline)
    assert :erlang.trace_pattern({Deadline, :check, 1}, true, []) == 1
    :erlang.trace(worker, true, [:call])

    try do
      send(worker, :go)
      assert_receive {:finished, ^worker, {:ok, _}}, 5_000
      delivered = :erlang.trace_delivered(worker)
      assert count_checks(worker, delivered, 0) > 4_096
    after
      :erlang.trace(worker, false, [:call])
      :erlang.trace_pattern({Deadline, :check, 1}, false, [])
      send(worker, :stop)
    end

    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
  end

  defp count_checks(worker, delivered, count) do
    receive do
      {:trace, ^worker, :call, {Deadline, :check, [_deadline]}} ->
        count_checks(worker, delivered, count + 1)

      {:trace_delivered, ^worker, ^delivered} ->
        count
    after
      5_000 -> flunk("deadline trace did not finish")
    end
  end

  test "scalar fields cannot hide nested depth or attributes from budgets" do
    assert {:error, {:limit, :max_xml_depth}} =
             parse("<loc><x><y><z>/a</z></y></x></loc>", %{max_xml_depth: 3})

    assert {:error, {:limit, :max_xml_attributes}} =
             parse("<loc><x a='1' b='2'>/a</x></loc>", %{max_xml_attributes: 1})
  end

  test "bounded malformed documents return explicit outcomes" do
    :rand.seed(:exsss, {901, 17, 402})

    chunks = [
      "<",
      ">",
      "</",
      "/>",
      "x",
      " ",
      "'",
      "\"",
      "=",
      "&",
      "<!--",
      "-->",
      "<![CDATA[",
      "]]>",
      "<?",
      "?>",
      "<loc>",
      "</loc>",
      "<description>",
      "</description>"
    ]

    opts = %{
      max_body: 4_096,
      max_control_entries: 32,
      max_control_token_bytes: 128,
      max_xml_depth: 16,
      max_xml_tokens: 256,
      max_xml_attributes: 8
    }

    for _ <- 1..300 do
      body = Enum.map_join(1..100, fn _ -> Enum.at(chunks, :rand.uniform(length(chunks)) - 1) end)
      result = parse(body, opts)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  test "common bases cannot amplify retained entry output past the analysis budget" do
    base = "https://example.test/" <> String.duplicate("a", 10_000) <> "/"

    body =
      ~s(<urlset xml:base="#{base}">) <>
        String.duplicate("<url><loc>x</loc></url>", 64) <> "</urlset>"

    assert byte_size(body) == 11_523

    assert {:ok, %{entries: entries, stats: stats}} =
             parse(body, %{max_analysis_bytes: 32_000_000})

    assert length(entries) == 64
    assert stats.base_resolutions == 1
    assert stats.output_binary_bytes == 1_283_328
    assert stats.output_metadata_bytes == 4_096 + 64 * 1_024
    assert stats.output_bytes == 1_352_960
    assert {:error, {:limit, :max_analysis_bytes}} = parse(body)
    assert {:error, {:limit, :max_analysis_bytes}} = parse(body, %{max_analysis_bytes: 1_000_000})
  end

  test "output charge includes every retained binary occurrence and entry metadata" do
    bodies = [
      ~s(<feed xml:base="/blog/"><entry><link href="post"/></entry><entry><link href="post"/></entry></feed>),
      ~s(<urlset><url><loc>/a</loc></url><url><loc>/b</loc></url></urlset>),
      "https://example.test/a\nhttps://example.test/b",
      ~s(<sitemapindex><sitemap><loc>a.xml</loc></sitemap><sitemap><loc>b.xml</loc></sitemap></sitemapindex>),
      ~s(<rss><channel><item><enclosure url="https://cdn.test/a"/><enclosure url="https://cdn.test/b"/></item></channel></rss>)
    ]

    for body <- bodies do
      assert {:ok, %{entries: entries, stats: stats} = document} = parse(body)

      binaries =
        for entry <- entries,
            value <- [entry.url, entry.raw, entry.effective_base | Map.values(entry.source)],
            is_binary(value),
            do: value

      assert stats.output_binary_bytes == Enum.sum(Enum.map(binaries, &byte_size/1))
      assert stats.output_metadata_bytes == 4_096 + length(entries) * 1_024
      assert stats.output_bytes == stats.output_binary_bytes + stats.output_metadata_bytes

      large_binary_bytes =
        binaries |> Enum.filter(&(byte_size(&1) > 64)) |> Enum.map(&byte_size/1) |> Enum.sum()

      assert stats.output_bytes >=
               :erts_debug.flat_size(document) * :erlang.system_info(:wordsize) +
                 large_binary_bytes

      assert stats.working_bytes == 0
      assert stats.peak_working_bytes > 0
      assert stats.peak_analysis_bytes > stats.output_bytes

      assert {:ok, %{stats: %{output_bytes: same}}} =
               parse(body, %{max_analysis_bytes: stats.peak_analysis_bytes})

      assert same == stats.output_bytes

      assert {:error, {:limit, :max_analysis_bytes}} =
               parse(body, %{max_analysis_bytes: stats.peak_analysis_bytes - 1})

      assert {:ok, %{stats: first}} = parse(~s(<urlset><url><loc>/a</loc></url></urlset>))

      assert {:error, {:limit, :max_analysis_bytes}} =
               parse(body, %{max_analysis_bytes: first.output_bytes})
    end
  end

  test "returned binary fields cannot pin the input body or caller URL backing binary" do
    document_url = "https://example.test/" <> String.duplicate("b", 96) <> "/root.xml"
    padded_url = String.duplicate("z", 100_000) <> document_url
    document_url = binary_part(padded_url, 100_000, byte_size(document_url))
    assert :binary.referenced_byte_size(document_url) > byte_size(document_url)
    field = "https://example.test/" <> String.duplicate("p", 96)

    body =
      ~s(<urlset><url><loc>#{field}</loc></url>) <> String.duplicate(" ", 30_000) <> "</urlset>"

    assert {:ok, %{entries: [entry]}} = Document.parse(body, document_url, limits())
    assert entry.raw == field
    assert entry.effective_base == document_url

    for value <- [entry.url, entry.raw, entry.effective_base | Map.values(entry.source)],
        is_binary(value) do
      assert :binary.referenced_byte_size(value) == byte_size(value)
    end
  end

  test "empty results have a fixed metadata charge and the seventh normalized limit is required" do
    assert {:ok, %{stats: stats}} = parse("<urlset/>")
    assert stats.working_bytes == 0
    assert stats.peak_analysis_bytes > 4_096
    assert {:ok, _} = parse("<urlset/>", %{max_analysis_bytes: stats.peak_analysis_bytes})

    assert {:error, {:limit, :max_analysis_bytes}} =
             parse("<urlset/>", %{max_analysis_bytes: stats.peak_analysis_bytes - 1})

    assert {:ok, %{stats: empty}} = parse("")
    assert empty.output_bytes == 4_096
    assert empty.peak_analysis_bytes == 4_096 + byte_size("https://example.test/maps/root.xml")
    assert {:ok, _} = parse("", %{max_analysis_bytes: empty.peak_analysis_bytes})

    assert {:error, {:limit, :max_analysis_bytes}} =
             parse("", %{max_analysis_bytes: empty.peak_analysis_bytes - 1})

    assert stats.output_bytes == 4_096
    assert stats.output_binary_bytes == 0
    assert stats.output_metadata_bytes == 4_096

    assert {:error, {:limit, :max_analysis_bytes}} =
             parse("<urlset/>", %{max_analysis_bytes: 4_095})

    assert_raise KeyError, fn ->
      Document.parse(
        "<urlset/>",
        "https://example.test/map.xml",
        Map.delete(limits(), :max_analysis_bytes)
      )
    end
  end

  test "oversized inherited bases are rejected before resolving an entry" do
    document_url = "https://example.test/" <> String.duplicate("b", 200)

    assert {:error, {:limit, :max_control_token_bytes}} =
             Document.parse(
               "<urlset><url><loc>x</loc></url></urlset>",
               document_url,
               limits(%{max_control_token_bytes: 128})
             )
  end

  test "large dynamic source names are copied and charged like URL fields" do
    parent_name = String.duplicate("p", 512)

    body =
      "<" <>
        parent_name <>
        ~s(><thumbnail url="https://cdn.test/image"/></) <>
        parent_name <> ">" <> String.duplicate(" ", 30_000)

    assert {:ok, %{entries: [entry], stats: stats}} = parse(body)
    assert entry.source.parent == parent_name
    assert entry.role == :image
    fields = [entry.url, entry.raw, entry.effective_base | Map.values(entry.source)]
    binaries = Enum.filter(fields, &is_binary/1)
    assert stats.output_binary_bytes == Enum.sum(Enum.map(binaries, &byte_size/1))

    for value <- binaries do
      assert :binary.referenced_byte_size(value) == byte_size(value)
    end
  end

  @tag timeout: 180_000
  test "the confirmed long-base fixture rejects before exceeding the shared charge" do
    base = "https://example.test/" <> String.duplicate("a", 63_978) <> "/"

    body =
      ~s(<urlset xml:base="#{base}">) <>
        String.duplicate(~s(<n xml:base=".">), 250) <>
        String.duplicate("<url><loc>x</loc></url>", 150) <>
        String.duplicate("</n>", 250) <> "</urlset>"

    assert byte_size(body) == 72_479
    {result, checks, calls, _charges} = traced_parse(body, %{})
    assert result == {:error, {:limit, :max_analysis_bytes}}
    assert calls == 1
    assert length(checks) > calls
    {output, working, limit} = List.last(checks)
    assert output == 4_096
    assert output + working > limit
    assert limit == 20_000_000

    assert Enum.all?(Enum.drop(checks, -1), fn {output, working, limit} ->
             output + working <= limit and working >= 0
           end)
  end

  test "a frame reservation fails before base URL resolution begins" do
    body =
      ~s(<feed xml:base="https://example.test/news/"><entry><link href="post"/></entry></feed>)

    {result, checks, calls, _charges} = traced_parse(body, %{max_analysis_bytes: 50_000})
    assert result == {:error, {:limit, :max_analysis_bytes}}
    assert calls == 0
    assert Enum.all?(Enum.drop(checks, -1), fn {out, work, max} -> out + work <= max end)
    {out, work, max} = List.last(checks)
    assert out + work > max
  end

  test "shared peak includes both active frames and retained output" do
    body =
      ~s(<feed xml:base="/blog/">) <>
        String.duplicate(~s(<n xml:base="./">), 16) <>
        "<entry>" <>
        String.duplicate(~s(<link href="post"/>), 80) <>
        "</entry>" <>
        String.duplicate("</n>", 16) <> "</feed>"

    assert {:ok, %{stats: stats}} = parse(body)
    assert stats.working_bytes == 0
    assert stats.peak_analysis_bytes > max(stats.output_bytes, 4_096 + stats.peak_working_bytes)
    assert stats.base_resolutions == 17
    assert {:ok, %{stats: same}} = parse(body, %{max_analysis_bytes: stats.peak_analysis_bytes})
    assert same == stats

    assert {:error, {:limit, :max_analysis_bytes}} =
             parse(body, %{max_analysis_bytes: stats.peak_analysis_bytes - 1})
  end

  test "closing a frame releases its charge before the next sibling" do
    branches = String.duplicate(~s(<n xml:base="./"><x/></n>), 12)
    body = "<urlset>" <> branches <> "</urlset>"
    assert {:ok, %{stats: many}} = parse(body)
    assert {:ok, %{stats: one}} = parse(~s(<urlset><n xml:base="./"><x/></n></urlset>))
    assert many.working_bytes == 0
    assert many.peak_analysis_bytes == one.peak_analysis_bytes
    assert many.peak_working_bytes == one.peak_working_bytes
    assert many.frames_created == 25
    assert many.base_resolutions == 12
    assert {:ok, _} = parse(body, %{max_analysis_bytes: one.peak_analysis_bytes})
  end

  test "temporary text, prose and self-closing frames release their charges" do
    for branch <- ["<loc>unused</loc>", "<description><x/></description>", "<x/>"] do
      body = "<urlset>" <> String.duplicate(branch, 20) <> "</urlset>"
      assert {:ok, %{stats: stats}} = parse(body)
      assert stats.working_bytes == 0
      assert stats.peak_analysis_bytes > stats.output_bytes
      assert {:ok, _} = parse(body, %{max_analysis_bytes: stats.peak_analysis_bytes})

      assert {:error, {:limit, :max_analysis_bytes}} =
               parse(body, %{max_analysis_bytes: stats.peak_analysis_bytes - 1})
    end
  end

  test "unfinished frame storage is discarded at the document boundary" do
    assert {:ok, %{stats: stats}} = parse(~s(<feed xml:base="/blog/"><entry><link href="post"/>))
    assert stats.working_bytes == 0
    assert stats.peak_working_bytes > 0
    assert stats.entries == 1
  end

  defp traced_parse(body, overrides) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          :go ->
            result = parse(body, overrides)
            send(parent, {:parsed, self(), result})

            receive do
              :stop -> :ok
            end
        end
      end)

    :erlang.trace_pattern({Budget, :capacity, 2}, true, [:local])
    :erlang.trace_pattern({Budget, :charge, 3}, true, [:local])
    :erlang.trace_pattern({Crawler.URL, :resolve_result, 3}, true, [:call_count])
    :erlang.trace(pid, true, [:call])

    try do
      send(pid, :go)
      assert_receive {:parsed, ^pid, result}, 120_000
      delivered = :erlang.trace_delivered(pid)
      {checks, charges} = collect_budget_checks(pid, delivered, [], [])
      {:call_count, calls} = :erlang.trace_info({Crawler.URL, :resolve_result, 3}, :call_count)
      {result, checks, calls, charges}
    after
      :erlang.trace(pid, false, [:call])
      :erlang.trace_pattern({Budget, :capacity, 2}, false, [:local])
      :erlang.trace_pattern({Budget, :charge, 3}, false, [:local])
      :erlang.trace_pattern({Crawler.URL, :resolve_result, 3}, false, [:call_count])
      send(pid, :stop)

      receive do
        {:DOWN, ^monitor, :process, ^pid, :normal} -> :ok
      after
        5_000 ->
          Process.exit(pid, :kill)
          assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000
      end
    end
  end

  defp collect_budget_checks(pid, delivered, checks, charges) do
    receive do
      {:trace, ^pid, :call, {Budget, :capacity, [budget, bytes]}} ->
        collect_budget_checks(
          pid,
          delivered,
          [{budget.retained, budget.scratch + bytes, budget.limit} | checks],
          charges
        )

      {:trace, ^pid, :call, {Budget, :charge, [budget, bytes, _counts]}} ->
        collect_budget_checks(pid, delivered, checks, [{budget.retained, bytes} | charges])

      {:trace_delivered, ^pid, ^delivered} ->
        {Enum.reverse(checks), Enum.reverse(charges)}
    after
      5_000 -> flunk("analysis budget trace did not finish")
    end
  end

  test "output reservation carries the live URL result charge until copying completes" do
    body = ~s(<feed><entry><link href="a"/><link href="b"/></entry></feed>)
    {result, checks, calls, charges} = traced_parse(body, %{})
    assert {:ok, %{stats: stats}} = result
    assert calls == 2
    assert [{0, 4_096}, {first_live, first_charge}, {second_live, second_charge}] = charges
    assert first_live > 4_096
    assert second_live > 4_096 + first_charge
    assert stats.output_bytes == 4_096 + first_charge + second_charge
    assert stats.working_bytes == 0
    assert Enum.all?(checks, fn {out, work, max} -> out + work <= max end)
  end

  test "later URL reservations keep earlier output and active frames charged" do
    body =
      ~s(<feed xml:base="/blog/">) <>
        String.duplicate(~s(<n xml:base="./">), 16) <>
        "<entry>" <>
        String.duplicate(~s(<link href="post"/>), 500) <>
        "</entry>" <>
        String.duplicate("</n>", 16) <> "</feed>"

    {result, checks, calls, charges} = traced_parse(body, %{max_analysis_bytes: 400_000})
    assert result == {:error, {:limit, :max_analysis_bytes}}
    assert calls > 17 and calls < 517
    assert length(charges) > 2
    {out, work, max} = List.last(checks)
    assert out > 4_096
    assert work > 0
    assert out + work > max
    assert max == 400_000
    assert Enum.all?(Enum.drop(checks, -1), fn {out, work, max} -> out + work <= max end)
  end

  test "Unicode host conversion uses the same residual document allowance" do
    body = ~s(<feed><entry><link href="https://bücher.example/a"/></entry></feed>)
    assert {:ok, %{entries: [entry], stats: stats}} = parse(body)
    assert entry.url == "https://xn--bcher-kva.example/a"
    assert stats.working_bytes == 0
    assert stats.peak_analysis_bytes > 200_000
    assert {:ok, _} = parse(body, %{max_analysis_bytes: stats.peak_analysis_bytes})

    assert {:error, {:limit, :max_analysis_bytes}} =
             parse(body, %{max_analysis_bytes: stats.peak_analysis_bytes - 1})

    :erlang.trace_pattern({Unicode.IDNA, :to_ascii, 2}, true, [:call_count])

    try do
      {result, checks, calls, _charges} = traced_parse(body, %{max_analysis_bytes: 200_000})
      assert result == {:error, {:limit, :max_analysis_bytes}}
      assert calls == 1
      assert {:call_count, 0} = :erlang.trace_info({Unicode.IDNA, :to_ascii, 2}, :call_count)
      assert Enum.all?(Enum.drop(checks, -1), fn {out, work, max} -> out + work <= max end)
      {out, work, max} = List.last(checks)
      assert out + work > max
    after
      :erlang.trace_pattern({Unicode.IDNA, :to_ascii, 2}, false, [:call_count])
    end
  end
end
