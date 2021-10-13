# Crawler Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## master

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
