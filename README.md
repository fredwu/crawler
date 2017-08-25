# Crawler

[![Travis](https://img.shields.io/travis/fredwu/crawler.svg)](https://travis-ci.org/fredwu/crawler)
[![Code Climate](https://img.shields.io/codeclimate/github/fredwu/crawler.svg)](https://codeclimate.com/github/fredwu/crawler)
[![CodeBeat](https://codebeat.co/badges/76916047-5b66-466d-91d3-7131a269899a)](https://codebeat.co/projects/github-com-fredwu-crawler-master)
[![Coverage](https://img.shields.io/coveralls/fredwu/crawler.svg)](https://coveralls.io/github/fredwu/crawler?branch=master)
[![Hex.pm](https://img.shields.io/hexpm/v/crawler.svg)](https://hex.pm/packages/crawler)

A high performance web crawler in Elixir, with worker pooling and rate limiting via [OPQ](https://github.com/fredwu/opq).

## Features

Crawler is under active development, below is a non-comprehensive list of features to be implemented.

- [x] Set the maximum crawl depth.
- [x] Save to disk.
- [x] Set timeouts.
- [x] Crawl assets.
  - [x] js
  - [x] css
  - [x] images
- [ ] The ability to manually stop/pause/restart the crawler.
- [ ] Restrict crawlable domains, paths or file types.
- [x] Limit concurrent crawlers.
- [x] Limit rate of crawling.
- [x] Set crawler's user agent.
- [ ] The ability to retry a failed crawl.
- [ ] DSL for scraping page content.

## Usage

```elixir
Crawler.crawl("http://elixir-lang.org", max_depths: 2)
```

## Configurations

| Option          | Type    | Default Value         | Description |
|-----------------|---------|-----------------------|-------------|
| `:max_depths`   | integer | `3`                   | Maximum nested depth of pages to crawl.
| `:workers`      | integer | `10`                  | Maximum number of concurrent workers for crawling.
| `:interval`     | integer | `0`                   | Rate limit control - number of milliseconds before crawling more pages, defaults to `0` which is effectively no rate limit.
| `:timeout`      | integer | `5000`                | Timeout value for fetching a page, in ms.
| `:user_agent`   | string  | `Crawler/x.x.x (...)` | User-Agent value sent by the fetch requests.
| `:save_to`      | string  | `nil`                 | When provided, the path for saving crawled pages.
| `:assets`       | list    | `[]`                  | Whether to fetch any asset files, available options: `"css"`, `"js"`, `"images"`.
| `:parser`       | module  | `Crawler.Parser`      | The default parser, useful when you need to handle parsing differently or to add extra functionalities.

## Custom Parser

It is possible to swap in your custom parsing logic by specifying the `:parser` option. Your custom parser needs to conform to the `Crawler.Parser.Spec` behaviour:

```elixir
defmodule CustomParser do
  @behaviour Crawler.Parser.Spec
end
```

## Changelog

Please see [CHANGELOG.md](CHANGELOG.md).

## License

Licensed under [MIT](http://fredwu.mit-license.org/).
