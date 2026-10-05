defmodule Crawler.RefreshLinkTest do
  use Crawler.TestCase, async: false

  alias Crawler.Linker
  alias Crawler.Store

  import Crawler.SnapshotHelpers

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
      root = tmp(unique_scope("refresh-link"))
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
          retries: 0,
          store: Store,
          scope: scope,
          save_to: root,
          req_options: context.req_options
        )

      await_idle(opts)
      assert Store.find_processed({landing, scope})
      assert Store.ops_count(scope) == 2

      saved_html = File.read!(saved(root, page))
      {:ok, document} = Floki.parse_document(saved_html)
      [saved_content] = Floki.attribute(document, "meta", "content")
      offline = Linker.offline_link(page, landing)
      assert saved_content == "0; url=#{quote}#{offline}#{quote}"

      <<"0; url=", saved_target::binary>> = saved_content

      href =
        if quote == "",
          do: saved_target,
          else: binary_part(saved_target, 1, byte_size(saved_target) - 2)

      opened = Path.expand(link_path(href), Path.dirname(saved(root, page)))
      assert File.read!(opened) == body
    end
  end

  defp escape_quotes(value), do: String.replace(value, "\"", "&quot;")
end
