defmodule Crawler.CrawlCssImportRulesTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers

  test "an import counts only in the stylesheet prelude", context do
    sheet = """
    @charset "utf-8";
    @layer reset, theme;
    @import "reset.css" layer(reset);
    @import "theme.css" layer(theme) supports(display: grid);
    @import "print.css" print;
    @layer components;
    @import "components.css";
    @namespace url("http://www.w3.org/2000/svg");
    @import "after-namespace.css";
    body { background: url("shown.png"); }
    @import "after-rule.css";
    """

    serve(context, "/prelude/start", "text/html", ~s|<link rel="stylesheet" href="sheet.css">|)
    serve(context, "/prelude/sheet.css", "text/css", sheet)
    serve(context, "/prelude/reset.css", "text/css", "reset")
    serve(context, "/prelude/theme.css", "text/css", "theme")
    serve(context, "/prelude/print.css", "text/css", "print")
    serve(context, "/prelude/shown.png", "image/png", "shown")

    root = crawl(context, "/prelude/start")
    saved = read(root, page(context, "/prelude/sheet.css"))

    assert saved =~ ~s|@import "components.css";|
    assert saved =~ ~s|@import "after-namespace.css";|
    assert saved =~ ~s|@import "after-rule.css";|
    assert saved =~ ~s|url("http://www.w3.org/2000/svg")|
    refute saved =~ ~s|@import "reset.css"|
  end

  test "a nested import is ignored and a picture in that rule still loads", context do
    sheet = """
    @import "ok.css" screen;
    @media screen {
      @import "no-media.css";
      body { background: url("shown.png"); }
    }
    @supports (display: grid) {
      @import "no-supports.css";
    }
    @supports (background: url("idle.png")) {
      p { background: url("yes.png"); }
    }
    @layer base {
      @import "no-layer.css";
    }
    @container (min-width: 10px) {
      @import "no-container.css";
      section { background: url("boxed.png"); }
    }
    div {
      @import "no-nested.css";
      background: url("inner.png");
    }
    """

    serve(context, "/nested/start", "text/html", ~s|<link rel="stylesheet" href="sheet.css">|)
    serve(context, "/nested/sheet.css", "text/css", sheet)
    serve(context, "/nested/ok.css", "text/css", "ok")
    serve(context, "/nested/shown.png", "image/png", "shown")
    serve(context, "/nested/yes.png", "image/png", "yes")
    serve(context, "/nested/boxed.png", "image/png", "boxed")
    serve(context, "/nested/inner.png", "image/png", "inner")

    crawl(context, "/nested/start")
  end

  test "a broken import loads nothing, including a picture in its block", context do
    sheet = """
    @import "one.css" url("two.css");
    @import "idle.css" "extra.css";
    @import "idle-layer.css" layer(one) layer(two);
    @import "idle-supports.css" supports();
    @import "blocked.css" {
      body { background: url("inner.png"); }
    }
    @import "ok.css" layer supports(display: grid) screen;
    @import "typed.css" supports(background: url("test.png"));
    """

    serve(context, "/broken/start", "text/html", ~s|<link rel="stylesheet" href="sheet.css">|)
    serve(context, "/broken/sheet.css", "text/css", sheet)
    serve(context, "/broken/ok.css", "text/css", "ok")
    serve(context, "/broken/typed.css", "text/css", "typed")

    root = crawl(context, "/broken/start")
    saved = read(root, page(context, "/broken/sheet.css"))

    assert saved =~ ~s|@import "blocked.css"|
    assert saved =~ ~s|url("inner.png")|
    assert saved =~ ~s|url("test.png")|
  end

  test "a custom property loads a picture only where an image value uses it", context do
    html = """
    <style>
    :root {
      --idle: url("idle.png");
      --bg: url("shown.png");
      --file: url("file.png");
      --alias: var(--file);
      --face: url("idle.woff2");
    }
    body { background: var(--bg); color: var(--idle); }
    p { background: var(--alias); }
    div { background: var(--missing, url("fallback.png")); }
    section { background: var(--bg, url("other.png")); }
    @font-face { font-family: Direct; src: url("shown.woff2") format("woff2"); }
    @font-face { font-family: Indirect; src: var(--face); }
    </style>
    """

    serve(context, "/vars/start", "text/html", html)
    serve(context, "/vars/shown.png", "image/png", "shown")
    serve(context, "/vars/file.png", "image/png", "file")
    serve(context, "/vars/fallback.png", "image/png", "fallback")
    serve(context, "/vars/shown.woff2", "font/woff2", "font")

    crawl(context, "/vars/start")
  end

  test "an unregistered picture uses the sheet that reads the variable", context do
    app = """
    @import "/tokens/tokens.css";
    html { background: var(--plain); }
    body { background: var(--icon); }
    """

    tokens = """
    @property --icon {
      syntax: "<url>";
      inherits: true;
      initial-value: url("initial.png");
    }
    :root { --icon: url("shown.png"); --plain: url("plain.png"); --idle: url("idle.png"); }
    """

    serve(context, "/cross/start", "text/html", ~s|<link rel="stylesheet" href="/css/app.css">|)
    serve(context, "/css/app.css", "text/css", app)
    serve(context, "/tokens/tokens.css", "text/css", tokens)
    serve(context, "/tokens/shown.png", "image/png", "shown")
    serve(context, "/css/plain.png", "image/png", "plain")

    root = crawl(context, "/cross/start")
    saved_app = read(root, page(context, "/css/app.css"))
    saved_tokens = read(root, page(context, "/tokens/tokens.css"))

    assert saved_app =~ "var(--plain)"
    assert saved_app =~ "var(--icon)"
    assert saved_tokens =~ ~s|url("plain.png")|
    assert saved_tokens =~ ~s|url("idle.png")|
    assert saved_tokens =~ ~s|url("initial.png")|
    refute saved_tokens =~ ~s|url("shown.png")|
  end

  test "an import that sets a variable skips its fallback", context do
    app = """
    @import "tokens.css";
    body { background: var(--bg, url("fallback.png")); }
    """

    tokens = """
    :root { --bg: url("shown.png"); }
    """

    serve(context, "/set/start", "text/html", ~s|<link rel="stylesheet" href="app.css">|)
    serve(context, "/set/app.css", "text/css", app)
    serve(context, "/set/tokens.css", "text/css", tokens)
    serve(context, "/set/shown.png", "image/png", "shown")

    root = crawl(context, "/set/start")
    saved = read(root, page(context, "/set/app.css"))

    assert saved =~ ~s|url("fallback.png")|
    assert saved =~ "var(--bg"
  end

  test "a missing import still loads the fallback picture", context do
    sheet = """
    @import "/missing/tokens.css";
    body { background: var(--bg, url("fallback.png")); }
    """

    serve(context, "/defer/start", "text/html", ~s|<link rel="stylesheet" href="sheet.css">|)
    serve(context, "/defer/sheet.css", "text/css", sheet)
    serve_missing(context, "/missing/tokens.css")
    serve(context, "/defer/fallback.png", "image/png", "fallback")

    root = crawl(context, "/defer/start")
    saved = read(root, page(context, "/defer/sheet.css"))

    assert saved =~ ~s|url("fallback.png")|
  end

  test "a style attribute is not a stylesheet", context do
    html = """
    <div style="@import 'idle.css'; background: url('shown.png')"></div>
    <svg><rect fill="url(paint.png)" stroke="@import 'idle.css'"/></svg>
    <p>@import "idle.css"</p>
    """

    serve(context, "/attr/start", "text/html", html)
    serve(context, "/attr/shown.png", "image/png", "shown")
    serve(context, "/attr/paint.png", "image/png", "paint")

    root = crawl(context, "/attr/start")
    saved = read(root, page(context, "/attr/start"))

    assert saved =~ "@import 'idle.css'"
    assert saved =~ ~s|@import "idle.css"|
    refute saved =~ "url('shown.png')"
    refute saved =~ "url(paint.png)"
  end

  test "a shared stylesheet joins the next document style group", context do
    sheet = """
    @property --mark { syntax: "<url>"; inherits: true; initial-value: url("init.png"); }
    :root { --logo: url("logo.png"); --mark: url("mark.png"); --idle: url("idle.png"); }
    """

    serve(context, "/pages/a.html", "text/html", """
    <link rel="stylesheet" href="/css/sheet.css">
    <a href="/pages/b.html">Next</a>
    """)

    serve(context, "/pages/b.html", "text/html", """
    <link rel="stylesheet" href="/css/sheet.css">
    <style>
      body { background: var(--logo); }
      h1 { background: var(--mark); }
    </style>
    """)

    serve(context, "/css/sheet.css", "text/css", sheet)
    serve(context, "/pages/logo.png", "image/png", "logo")
    serve(context, "/css/mark.png", "image/png", "mark")

    crawl(context, "/pages/a.html", workers: 1)
  end

  defp serve(%{site: site}, path, type, body) do
    ReqTestSite.expect_once(site, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", type)
      |> Plug.Conn.resp(200, body)
    end)
  end

  defp serve_missing(%{site: site}, path) do
    ReqTestSite.expect_once(site, "GET", path, fn conn ->
      Plug.Conn.resp(conn, 404, "missing")
    end)
  end

  defp crawl(context, path, extra \\ []) do
    scope = unique_scope("css-import")

    {:ok, opts} =
      start_crawl(
        page(context, path),
        Keyword.merge(
          [
            scope: scope,
            assets: ["css", "images"],
            max_depths: 3,
            retries: 0,
            workers: 2,
            save_to: tmp(scope),
            req_options: context.req_options
          ],
          extra
        )
      )

    await_idle(opts)
    tmp(scope)
  end

  defp page(%{url: url}, path), do: url <> path
  defp read(root, url), do: File.read!(saved(root, url))
end
