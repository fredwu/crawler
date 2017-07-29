# Crawler [![Travis](https://img.shields.io/travis/fredwu/crawler.svg)](https://travis-ci.org/fredwu/crawler) [![Hex.pm](https://img.shields.io/hexpm/v/crawler.svg)](https://hex.pm/packages/crawler)

A high performance web crawler in Elixir.

## Usage

```elixir
Crawler.crawl("http://elixir-lang.org")
```

## Configurations

| Option      | Type    | Default Value | Description |
|-------------|---------|---------------|-------------|
| :max_levels | integer | 3             | Maximum nested level of pages to crawl.


### Example

```elixir
Crawler.crawl("http://elixir-lang.org", max_levels: 5)
```

## License

Licensed under [MIT](http://fredwu.mit-license.org/).
