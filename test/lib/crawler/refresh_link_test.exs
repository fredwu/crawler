defmodule Crawler.RefreshLinkTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  import Crawler.ManagedSnapshotHelpers

  for {name, target, quote, expected_target} <- [
        {"unquoted path", "/refresh/next;v=2", "", "/refresh/next;v=2"},
        {"unquoted query", "/refresh/next?q=1;v=2", "", "/refresh/next?q=1;v=2"},
        {"single-quoted path", "/refresh/next;v=2", "'", "/refresh/next;v=2"},
        {"double-quoted query", "/refresh/next?q=1;v=2", "\"", "/refresh/next?q=1;v=2"},
        {"double-quoted apostrophe query", "/refresh/next?name=O'Reilly", "\"",
         "/refresh/next?name=O%27Reilly"},
        {"single-quoted double-quote query", ~s|/refresh/next?name="Reilly"|, "'",
         "/refresh/next?name=%22Reilly%22"}
      ] do
    test "fetches and opens the complete #{name} target", context do
      target = unquote(target)
      quote = unquote(quote)
      page = "#{context.url}/refresh/page"
      landing = context.url <> unquote(expected_target)

      root =
        Path.join(
          tmp(),
          unique_scope("refresh-link") <> "-#{Base.encode16(:crypto.strong_rand_bytes(6))}"
        )

      on_exit(fn -> File.rm_rf(root) end)
      scope = unique_scope("refresh-link")
      destination = URI.parse(landing)
      assert URI.decode(destination.query || "") == (URI.parse(target).query || "")
      content = "0; url=#{quote}#{target}#{quote}"
      html = ~s|<meta http-equiv="refresh" content="#{escape_quotes(content)}">|
      body = "REFRESH #{target}"

      ReqTestSite.expect_once(context.site, "GET", "/refresh/page", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.resp(200, html)
      end)

      ReqTestSite.expect_once(context.site, "GET", destination.path, fn conn ->
        assert conn.query_string == (destination.query || "")

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.resp(200, body)
      end)

      {:ok, opts} =
        start_crawl(page,
          workers: 1,
          max_body: 1_048_576,
          max_analysis_bytes: 16_000_000,
          max_css_work: 5_000,
          max_css_pictures: 1_000,
          retries: 0,
          store: Store,
          scope: scope,
          save_to: root,
          req_options: context.req_options
        )

      export = ready_export(opts)
      source = resource_for_url(export, page)
      target_resource = reference_target(export, source, landing)
      assert Store.find_processed({landing, scope})
      assert Store.ops_count(scope) == 2

      saved_html = read_resource(export, source)
      {:ok, document} = Floki.parse_document(saved_html)
      [saved_content] = Floki.attribute(document, "meta", "content")
      offline = relative_reference(source, target_resource)
      assert saved_content == "0; url=#{quote}#{offline}#{quote}"

      <<"0; url=", saved_target::binary>> = saved_content

      href =
        if quote == "",
          do: saved_target,
          else: binary_part(saved_target, 1, byte_size(saved_target) - 2)

      assert_opens(export, source, target_resource, href)
      assert read_resource(export, target_resource) == body
    end
  end

  defp escape_quotes(value), do: String.replace(value, "\"", "&quot;")
end
