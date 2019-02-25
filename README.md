# Crawler

[![Travis](https://img.shields.io/travis/fredwu/crawler.svg)](https://travis-ci.org/fredwu/crawler)
[![CodeBeat](https://codebeat.co/badges/76916047-5b66-466d-91d3-7131a269899a)](https://codebeat.co/projects/github-com-fredwu-crawler-master)
[![Coverage](https://img.shields.io/coveralls/fredwu/crawler.svg)](https://coveralls.io/github/fredwu/crawler?branch=master)
[![Hex.pm](https://img.shields.io/hexpm/v/crawler.svg)](https://hex.pm/packages/crawler)

A high performance web crawler in Elixir, with worker pooling and rate limiting via [OPQ](https://github.com/fredwu/opq).

## Features

- Crawl assets (javascript, css and images).
- Save to disk.
- Hook for scraping content.
- Restrict crawlable domains, paths or content types.
- Limit concurrent crawlers.
- Limit rate of crawling.
- Set the maximum crawl depth.
- Set timeouts.
- Set retries strategy.
- Set crawler's user agent.
- Manually pause/resume/stop the crawler.

## Architecture

Below is a very high level architecture diagram demonstrating how Crawler works.

![](https://rawgit.com/fredwu/crawler/master/architecture.svg)

## Usage

```elixir
Crawler.crawl("http://elixir-lang.org", max_depths: 2)
```

There are several ways to access the crawled page data:

1. Use [`Crawler.Store`](https://hexdocs.pm/crawler/Crawler.Store.html)
2. Tap into the registry([?](https://hexdocs.pm/elixir/Registry.html)) [`Crawler.Store.DB`](lib/crawler/store.ex)
3. Use your own [scraper](#custom-modules)
4. If the `:save_to` option is set, pages will be saved to disk in addition to the above mentioned places
5. Provide your own [custom parser](#custom-modules) and manage how data is stored and accessed yourself

## Configurations

| Option          | Type    | Default Value               | Description |
|-----------------|---------|-----------------------------|-------------|
| `:assets`       | list    | `[]`                        | Whether to fetch any asset files, available options: `"css"`, `"js"`, `"images"`.
| `:save_to`      | string  | `nil`                       | When provided, the path for saving crawled pages.
| `:workers`      | integer | `10`                        | Maximum number of concurrent workers for crawling.
| `:interval`     | integer | `0`                         | Rate limit control - number of milliseconds before crawling more pages, defaults to `0` which is effectively no rate limit.
| `:max_depths`   | integer | `3`                         | Maximum nested depth of pages to crawl.
| `:timeout`      | integer | `5000`                      | Timeout value for fetching a page, in ms. Can also be set to `:infinity`, useful when combined with `Crawler.pause/1`.
| `:user_agent`   | string  | `Crawler/x.x.x (...)`       | User-Agent value sent by the fetch requests.
| `:url_filter`   | module  | `Crawler.Fetcher.UrlFilter` | Custom URL filter, useful for restricting crawlable domains, paths or content types.
| `:retrier`      | module  | `Crawler.Fetcher.Retrier`   | Custom fetch retrier, useful for retrying failed crawls.
| `:modifier`     | module  | `Crawler.Fetcher.Modifier`  | Custom modifier, useful for adding custom request headers or options.
| `:scraper`      | module  | `Crawler.Scraper`           | Custom scraper, useful for scraping content as soon as the parser parses it.
| `:parser`       | module  | `Crawler.Parser`            | Custom parser, useful for handling parsing differently or to add extra functionalities.
| `:encode_uri`   | boolean | `false`                     | When set to `true` apply the `URI.encode` to the URL to be crawled.

## Custom Modules

It is possible to swap in your custom logic as shown in the configurations section. Your custom modules need to conform to their respective behaviours:

### Retrier

See [`Crawler.Fetcher.Retrier`](lib/crawler/fetcher/retrier.ex).

Crawler uses [ElixirRetry](https://github.com/safwank/ElixirRetry)'s exponential backoff strategy by default.

```elixir
defmodule CustomRetrier do
  @behaviour Crawler.Fetcher.Retrier.Spec
end
```

### URL Filter

See [`Crawler.Fetcher.UrlFilter`](lib/crawler/fetcher/url_filter.ex).

```elixir
defmodule CustomUrlFilter do
  @behaviour Crawler.Fetcher.UrlFilter.Spec
end
```

### Scraper

See [`Crawler.Scraper`](lib/crawler/scraper.ex).

```elixir
defmodule CustomScraper do
  @behaviour Crawler.Scraper.Spec
end
```

### Parser

See [`Crawler.Parser`](lib/crawler/parser.ex).

```elixir
defmodule CustomParser do
  @behaviour Crawler.Parser.Spec
end
```

### Modifier

See [`Crawler.Fetcher.Modifier`](lib/crawler/fetcher/modifier.ex).

```elixir
defmodule CustomModifier do
  @behaviour Crawler.Fetcher.Modifier.Spec
end
```

## Pause / Resume / Stop Crawler

Crawler provides `pause/1`, `resume/1` and `stop/1`, see below.

```elixir
{:ok, opts} = Crawler.crawl("http://elixir-lang.org")

Crawler.pause(opts)

Crawler.resume(opts)

Crawler.stop(opts)
```

Please note that when pausing Crawler, you would need to set a large enough `:timeout` (or even set it to `:infinity`) otherwise parser would timeout due to unprocessed links.

## API Reference

Please see https://hexdocs.pm/crawler.

## Changelog

Please see [CHANGELOG.md](CHANGELOG.md).

## License

Licensed under [MIT](http://fredwu.mit-license.org/).
