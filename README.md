# Crawler [![Travis](https://img.shields.io/travis/fredwu/crawler.svg)](https://travis-ci.org/fredwu/crawler) [![Hex.pm](https://img.shields.io/hexpm/v/crawler.svg)](https://hex.pm/packages/crawler)

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

Crawler is under active development, below is the list of features to be implemented.

|     | Feature |
|-----|---------|
| [x] | Set the maximum crawl level.
| [ ] | Restrict crawlable domains and/or path.
| [ ] | Limit concurrent crawlers.
| [ ] | Limit rate of crawling.
| [ ] | Set crawler's user agent.
| [ ] | The ability to retry a failed crawl.
| [ ] | DSL for scraping page content.

## License

Licensed under [MIT](http://fredwu.mit-license.org/).
