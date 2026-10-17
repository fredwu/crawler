# Crawler Changelog

## master

- [Fixed] Read a stylesheet only when the response is CSS, and a script only when the response is JavaScript. Plain text, CSV, and markdown stay text, including in the offline copy. An HTML or plain-text response served for a stylesheet or script does not add its links. CSS or JavaScript opened from an ordinary link is still read as that type. An RSS or Atom feed, and a sitemap or feed linked from a page, contributes its pages the same way a robots sitemap does. That file does not use a page slot. Canonical links, language alternates, dns-prefetch, and preconnect stay unfetched.
- [Fixed] Save the source map named by a script, a stylesheet, or a SourceMap header, and save the original files that map names. The header wins over the note. The map is resolved from the file that arrived, and only an inline script's sourceURL moves that base. A data map is not a request, and a saved one still contains a hash from the map. A saved map drops sourceRoot once a source path is offline, so that path is not prefixed again. An empty sourceRoot does not move a source. A classic script reads the note with that script's rules.
- [Fixed] Follow prefetch, prerender, next, prev, manifest, preload fetch and track, and speculation rules, and save those files. A disabled stylesheet stays as written. Nofollow still skips next and prev, not these subresources.
- [Fixed] Follow import maps, `new URL(..., import.meta.url)`, workers, and `importScripts`, and save those same files. A later map can add a name but cannot replace one. Classic scripts fetch `import()` only. Workers do not use the page import map.
- [Fixed] Send cookies with SameSite and partition rules for the page that caused the request. The default is Lax. SameSite=None is stored only when the cookie is Secure and the response is https. A document navigation to another site sends Lax and not Strict. A script, image, stylesheet, font, frame, object, or embed on another site does not. A partitioned cookie follows that page's registrable domain. Longer paths are sent first, and replacing a cookie keeps its earlier place.
- [Fixed] Crawl pages named by a robots sitemap, including prefixed XML, text lists, RSS and Atom feeds, and language versions. Image and video files are fetched when image assets are collected. A sitemap index keeps going while page budget remains, without counting a finished page twice or reserving a disallowed or repeated URL. A failed sitemap is retried, and a UTF-16 sitemap is read.
- [Fixed] Refuse a redirect when the next URL is disallowed by that URL's robots.txt, including a page, script, stylesheet, image, or sitemap file. Do not download a sitemap file whose own address is disallowed. A sitemap URL the crawl will not fetch, including one the URL filter or the depth limit rejects, does not take a page slot. Checking robots.txt for one URL on another host does not read the sitemaps that host lists. `respect_robots: false` still follows these redirects.
- [Fixed] Keep the browser address as the request and the stored page. One trailing DNS dot stays, so `example.com.` is a different host from `example.com`. Userinfo is encoded, and a rejected authority is not fetched. A bare percent sign, a path pipe, and the query characters backtick, brace, pipe, backslash, and caret stay literal and do not share a page with their percent-encoded forms. `%2e` is a dot only as a whole path segment.
- [Fixed] Store `__Host-` and `__Secure-` cookies only when the prefix rules pass. An http response cannot create or replace a Secure cookie. The first request keeps caller Cookie, Authorization, and custom headers on the seed hostname only, and a later hop on another host does not receive the caller cookie. A scheme URL in the User-Agent comment does not select a robots group.
- [Added] Add `:respect_robots` and `:max_body`. The crawler can honour robots.txt and nofollow, keep ordinary links on the seed site, and limit the decoded response size.
- [Fixed] Keep cookies for one crawl scope. A redirect rebuilds Cookie for the next URL. The same host keeps the caller's Cookie, Authorization, and other custom headers when the scheme or port changes. Another host does not receive them. A response after the scope is reset does not restore the jar. A robots server error blocks that fetch and is requested again. Gzip and deflate responses are read as the decoded page. A missing content type is not treated as HTML. Status 200 and 203 are kept. JavaScript types with a charset parameter are fetched and rewritten.
- [Fixed] Stop managed queues when Store restarts and prevent old jobs on external queues from updating new crawl state. Initial URL-filter errors return unchanged without fetching or retrying, and error logs omit callback reasons.
- [Fixed] Correct URL resolution, target schemes, equivalent spellings and sanitized fragments, charset parameters and media types, and HTML/CSS/JavaScript reference boundaries. Discovery and offline rewriting share HTML asset selection and JavaScript goals, and preserve policy roles, encoded image candidates and base targets. Reduce repeated copying in HTML rewrites and CSS comments; clear snapshot test scopes during teardown.
- [Fixed] Running status follows the requested scope, and failed redirect fallbacks release pending work. Later redirects preserve completed landing snapshots. Tagged HTTP failures retry; callback and programming exceptions keep their original stack. Keep staging paths separate from archived page filenames. Completed snapshot attempts release staging watchers, while caller death still removes partial files.
- [Fixed] Discovery and rewriting share decoded CSS/JavaScript links and source boundaries, including escaped URLs, function expressions, quoted bindings, and declaration boundaries. JavaScript recognizes complete module keywords and preserves property names; invalid CSS URLs remain unchanged. HTML recovers malformed attribute boundaries, uses active document bases, respects foreign-content contexts and first duplicate charset attributes, and treats HTML meta UTF-16 labels as UTF-8. Saved links preserve unrelated text and remove stale preload integrity attributes.
- [Fixed] Canonicalize browser hosts, validate authorities, and send ASCII request targets while preserving empty queries and Finch callbacks. Use `:redirect` for redirect policy and merge request headers case-insensitively. Keep offline fragments within source boundaries, dot-only hosts inside the output directory, and NFC-equivalent paths in separate archive files. Return safe structured snapshot errors, omit credentials from diagnostics, and patch affected HTTP dependencies.
- [Improved] Test waits use deadlines. Fixture cleanup waits for callback termination before releasing owned processes. The Google Search example restricts exact hosts, rejects credentials, uses a bounded wait, and releases its resources.
- [Improved] Require Elixir 1.17 or later for Unicode dependencies. Document module ownership, scoped page access, queue and timeout behavior, and contributor verification commands.
- [Fixed] A saved link opens the page that was fetched. A redirect is stored under both the requested address and the address it landed on, and a redirect the crawl would reject is not saved or followed. A blank redirect is not followed, and a redirect past the hop limit stays a too-many-redirects error. `http` and `https`, a username or password, a bare `?`, and path case, letters that case-fold to the same spelling, and a decomposed Hangul syllable no longer share one file.
- [Fixed] Addresses a browser treats as the same page are fetched once and saved as one file. The store key drops the fragment, and a saved link keeps it. `http` and `https`, userinfo, path case, an encoded slash, an empty query, and query order stay separate pages unless an allowed redirect stores the landing page under both addresses.
- [Added] A text response is decoded from its BOM, HTTP charset, HTML meta charset, XHTML XML encoding declaration, or leading CSS charset declaration and saved as UTF-8. HTML charset declarations, leading CSS declarations, and XHTML XML encoding declarations are rewritten to `utf-8`. Non-text bodies stay as received.
- [Added] Add `:retries` option
- [Improved] Replace HTTPoison/Bypass HTTP handling and tests with Req/Req.Test.
- [Fixed] Stopping a crawl shuts down the queue processes it started, without changing the caller's exit trapping, and releases that scope's URLs, counters, and in-flight slots
- [Fixed] A failed or crashed URL is fetched once per crawl and can be retried after the crawl is idle
- [Fixed] Saving a page no longer blocks other crawls, and an unfinished older save cannot replace a newer crawl of the same page
- [Fixed] Linked pages no longer inherit the parent page's redirect alias or response headers
- [Fixed] Passing a stopped queue no longer pins that scope's counters
- [Fixed] Stopping a crawl removes a page file that was still being written

## v1.5.0 [2023-10-10]

- [Added] Add `:force` option
- [Added] Add `:scope` option

## v1.4.0 [2023-10-07]

- [Added] Allow multiple instances of Crawler sharing the same queue
- [Improved] Logger will now log entries as `debug` or `warn`

## v1.3.0 [2023-09-30]

- [Added] `:store` option, defaults to `nil` to save memory usage
- [Added] `:max_pages` option
- [Added] `Crawler.running?/1` to check whether Crawler is running
- [Improved] The queue is being supervised now

## v1.2.0 [2023-09-29]

- [Added] `Crawler.Store.all_urls/0` to find all scraped URLs
- [Improved] Memory usage optimisations

## v1.1.2 [2021-10-14]

- [Improved] Documentation improvements (thanks @kianmeng)

## v1.1.1 [2020-05-15]

- [Improved] Updated `floki` and other dependencies

## v1.1.0 [2019-02-25]

- [Added] `:modifier` option
- [Added] `:encode_uri` option
- [Improved] Varies small fixes and improvements

## v1.0.0 [2017-08-31]

- [Added] Pause / resume / stop Crawler
- [Improved] Varies small fixes and improvements

## v0.4.0 [2017-08-28]

- [Added] `:scraper` option to allow scraping content
- [Improved] Varies small fixes and improvements

## v0.3.1 [2017-08-28]

- [Improved] `Crawler.Store.DB` now stores the `opts` meta data
- [Improved] Code documentation
- [Improved] Varies small fixes and improvements

## v0.3.0 [2017-08-27]

- [Added] `:retrier` option to allow custom fetch retrying logic
- [Added] `:url_filter` option to allow custom url filtering logic
- [Improved] Parser is now more stable and skips unparsable files
- [Improved] Varies small fixes and improvements

## v0.2.0 [2017-08-21]

- [Added] `:workers` option
- [Added] `:interval` option
- [Added] `:timeout` option
- [Added] `:user_agent` option
- [Added] `:save_to` option
- [Added] `:assets` option
- [Added] `:parser` option to allow custom parsing logic
- [Improved] Renamed `:max_levels` to `:max_depths`
- [Improved] Varies small fixes and improvements

## v0.1.0 [2017-07-30]

- [Added] A semi-functioning prototype
- [Added] Finished the very basic crawling function
- [Added] `:max_levels` option
