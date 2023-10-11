# Crawler Changelog

## master

- [Added] Add `:retries` option
- [Changed] Revert `:store` option default back to `Store`

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
