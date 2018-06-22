defmodule Crawler.Fetcher.Modifier do
    
    @moduledoc """
        modify request options and headers before dispatch 
    """

    defmodule Spec do
        @moduledoc """
        Spec for defining a request modifier.
        """

        @type url  :: String.t
        @type header :: {String.t, String.t}
        @type opts :: map

        @callback headers(opts) :: list(header) | []
        @callback opts(opts)   :: keyword | []

    end

    @behaviour __MODULE__.Spec

    @doc """
    Allows modifing headers prior to making the crawl request

    ## Example implementaion

        def headers(opts) do
            if opts[:url] == "http://modifier" do
                [{"Referer", "http://fetcher"}]  
            end
            []
        end

    """
    def headers(_opts), do: []

    @doc """
    Allows passing opts to httpPoison prior to making the crawl request
      
    ## Example implementation
 
        def opts(opts) do
            if opts[:url] == "http://modifier" do
                # add a new pool to hackney
                [hackney: [pool: :modifier]] 
            end
            []
        end
        
    """
    def opts(_opts), do: []

end