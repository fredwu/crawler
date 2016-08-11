use Amnesia

defdatabase CrawlerDB do
  deftable Page, [:url, :body, :parent_url], index: [:parent_url], type: :bag do
    @type t :: %Page{
      url: String.t, parent_url: String.t, body: String.t
    }

    def add(url, body, parent_url \\ "") do
      %Page{url: url, body: body, parent_url: parent_url} |> Page.write!
    end

    def find(url) do
      Page.read!(url) |> Enum.at(0)
    end

    def pages(parent_url) do
      Page.read_at!(parent_url, :parent_url)
    end
  end
end
