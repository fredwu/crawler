# Crawler [![Travis](https://img.shields.io/travis/fredwu/crawler.svg)](https://travis-ci.org/fredwu/crawler) [![Coverage](https://coveralls.io/repos/github/fredwu/crawler/badge.svg?branch=master)](https://coveralls.io/github/fredwu/crawler?branch=master) [![Hex.pm](https://img.shields.io/hexpm/v/crawler.svg)](https://hex.pm/packages/crawler)

A high performance web crawler in Elixir.

## Usage

```elixir
Crawler.crawl("http://elixir-lang.org", max_levels: 2)
```

## Configurations

| Option      | Type    | Default Value | Description |
|-------------|---------|---------------|-------------|
| :max_levels | integer | 3             | Maximum nested level of pages to crawl.

## Features Backlog

Crawler is under active development, below is a non-comprehensive list of features to be implemented.

- [x] Set the maximum crawl level.
- [ ] Save to disk.
- [ ] Set timeouts.
- [ ] The ability to manually stop/pause/restart the crawler.
- [ ] Restrict crawlable domains, paths or file types.
- [ ] Limit concurrent crawlers.
- [ ] Limit rate of crawling.
- [ ] Set crawler's user agent.
- [ ] The ability to retry a failed crawl.
- [ ] DSL for scraping page content.

## License

Licensed under [MIT](http://fredwu.mit-license.org/).
