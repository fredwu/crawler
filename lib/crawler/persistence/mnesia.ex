use Amnesia

defdatabase CrawlerDB do
  deftable Page,
    [{:id, autoincrement}, :parent_id, :url, :body],
    type: :bag,
    index: [:parent_id, :url]
  do
    @type t :: %Page{
      id: integer, parent_id: integer, url: String.t, body: String.t
    }

    def add(parent_id, url, body) do
      %Page{parent_id: parent_id, url: url, body: body} |> Page.write!
    end

    def find(url) do
      Page.read_at!(url, :url) |> Enum.at(0)
    end

    def pages(parent_id) do
      Page.read_at!(parent_id, :parent_id)
    end
  end
end
