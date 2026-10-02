# Crawler Changelog

## master

- [Fixed] A saved link opens the page that was fetched. A redirect is stored under both the requested address and the address it landed on, and a redirect the crawl would reject is not saved or followed. A blank redirect is not followed, and a redirect past the hop limit stays a too-many-redirects error. `http` and `https`, a username or password, a bare `?`, and path case, letters that case-fold to the same spelling, and a decomposed Hangul syllable no longer share one file.
- [Fixed] Addresses a browser treats as the same page are fetched once and saved as one file. The store key drops the fragment, and a saved link keeps it. `http` and `https`, userinfo, path case, an encoded slash, an empty query, and query order stay separate pages unless an allowed redirect stores the landing page under both addresses.
- [Added] A text response is decoded from its BOM, HTTP charset, or HTML meta charset and saved as UTF-8. An HTML charset declaration that named another known encoding is rewritten to `utf-8`. CSS and non-text bodies stay as received.
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
