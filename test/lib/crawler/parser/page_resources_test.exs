defmodule Crawler.Parser.PageResourcesTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser
  alias Crawler.Snapper.LinkReplacer

  @page "http://example.com/dir/page"
  @start "http://example.com/start"
  @blog "http://example.com/blog/"

  test "an html image tag reads src and srcset" do
    source = """
    <image href="not-a-picture.svg" src="photo.png" srcset="photo-2x.png 2x">
    <img src="real.png">
    <svg><image src="nope.png" href="sprite.svg"/></svg>
    <math><image src="math.png"></image></math>
    """

    assert found(source, ["images"]) == [
             {"photo.png", asset("photo.png"), "img", nil, "image"},
             {"photo-2x.png", asset("photo-2x.png"), "img", nil, "image"},
             {"real.png", asset("real.png"), "img", nil, "img"},
             {"sprite.svg", asset("sprite.svg"), "img", nil, "image"}
           ]

    assert found(source, []) == []

    saved = rewrite(source, ["images"])
    assert saved =~ "<image"
    assert saved =~ ~s|href="not-a-picture.svg"|
    assert saved =~ ~s|src="nope.png"|
    assert saved =~ ~s|src="math.png"|
    assert saved =~ asset("photo.png")
    assert saved =~ asset("photo-2x.png")
    assert saved =~ asset("real.png")
    assert saved =~ asset("sprite.svg")
    refute saved =~ ~s|src="photo.png"|
    refute saved =~ ~s|srcset="photo-2x.png 2x"|
    refute saved =~ ~s|src="real.png"|
    refute saved =~ ~s|href="sprite.svg"|

    quiet = rewrite(source, [])
    assert quiet =~ ~s|src="photo.png"|
    assert quiet =~ "photo-2x.png"
    assert quiet =~ ~s|src="real.png"|
    assert quiet =~ ~s|href="sprite.svg"|
  end

  test "a legacy background attribute is an image" do
    source = """
    <base href="#{@blog}">
    <body bgcolor="red" background="bg.jpg" alink="navy">
    <table background="table.png">
    <thead background="head.png"></thead>
    <tbody background="body.png">
    <tr background="row.png">
    <td background="cell.png"></td>
    <td>plain</td>
    <th background="heading.png" crossorigin="anonymous"></th>
    </tr>
    </tbody>
    <tfoot background="foot.png"></tfoot>
    </table>
    <div background="nope.png"></div>
    </body>
    """

    opts = %{url: @start, assets: ["images"]}

    assert found(source, opts) == [
             {"bg.jpg", blog("bg.jpg"), "img", nil, "body"},
             {"table.png", blog("table.png"), "img", nil, "table"},
             {"head.png", blog("head.png"), "img", nil, "thead"},
             {"body.png", blog("body.png"), "img", nil, "tbody"},
             {"row.png", blog("row.png"), "img", nil, "tr"},
             {"cell.png", blog("cell.png"), "img", nil, "td"},
             {"heading.png", blog("heading.png"), "img", nil, "th"},
             {"foot.png", blog("foot.png"), "img", nil, "tfoot"}
           ]

    assert credentials(source, opts) == [
             {"bg.jpg", :include, false},
             {"table.png", :include, false},
             {"head.png", :include, false},
             {"body.png", :include, false},
             {"row.png", :include, false},
             {"cell.png", :include, false},
             {"heading.png", :same_origin, false},
             {"foot.png", :include, false}
           ]

    assert found(source, %{url: @start, assets: []}) == []

    saved = rewrite(source, opts)

    for name <- ~w(bg.jpg table.png head.png body.png row.png cell.png heading.png foot.png) do
      assert saved =~ blog(name)
      refute saved =~ ~s|background="#{name}"|
    end

    assert saved =~ ~s|bgcolor="red"|
    assert saved =~ ~s|alink="navy"|
    assert saved =~ ~s|background="nope.png"|
    assert saved =~ "<td>plain</td>"

    quiet = rewrite(source, %{url: @start, assets: []})

    for name <- ~w(bg.jpg table.png head.png body.png row.png cell.png heading.png foot.png) do
      assert quiet =~ ~s|background="#{name}"|
    end

    assert quiet =~ ~s|bgcolor="red"|
    assert quiet =~ ~s|background="nope.png"|
  end

  defp found(source, assets) when is_list(assets), do: found(source, %{assets: assets})

  defp found(source, opts) do
    source
    |> Parser.parse_links(page_opts(opts), fn
      {_, raw, _, url}, link_opts -> link_tuple(raw, url, link_opts)
      {_, url}, link_opts -> link_tuple(url, url, link_opts)
    end)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp credentials(source, opts) do
    source
    |> Parser.parse_links(page_opts(opts), fn
      {_, raw, _, _url}, link_opts -> credential_tuple(raw, link_opts)
      {_, url}, link_opts -> credential_tuple(url, link_opts)
    end)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp credential_tuple(raw, opts) do
    {raw, Map.get(opts, :credentials, :include), opts.page_open}
  end

  defp link_tuple(raw, url, opts) do
    {raw, url, opts.html_tag, opts[:javascript_goal], opts.reference_tag}
  end

  defp page_opts(opts) do
    Map.merge(%{url: @page, content_type: "text/html", html_tag: "a"}, opts)
  end

  defp rewrite(source, assets) when is_list(assets), do: rewrite(source, %{assets: assets})

  defp rewrite(source, opts) do
    opts = page_opts(opts)
    opts = Map.put_new(opts, :referrer_url, opts.url)

    assert {:ok, body} = LinkReplacer.replace_links(source, opts)
    body
  end

  defp asset(name), do: "http://example.com/dir/" <> name
  defp blog(name), do: @blog <> name
end
