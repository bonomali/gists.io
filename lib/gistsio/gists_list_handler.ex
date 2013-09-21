defmodule GistsIO.GistsListHandler do
	alias :cowboy_req, as: Req
	require EEx

	def init(_transport, _req, []) do
		{:upgrade, :protocol, :cowboy_rest}
	end

	def allowed_methods(req, state) do
		{["GET"], req, state}
	end

	def content_types_provided(req, state) do
		{[
			{"text/html", :gist_html}
		], req, state}
	end

	def resource_exists(req, state) do
		case Req.binding :gist, req do
			{:undefined, req} -> {:false, req, :index}
			{gistId, req} -> 
				gist = GistFetcher.parse_gist gistId
				files = gist["files"]
				if files !== nil and Enum.any?(files, &is_markdown/1) do
					{:true, req, gist}
				else
					{:false, req, gist}
				end
		end
	end

	def gist_html(req, gist) do
		files = gist["files"]
		{_name, attrs} = Enum.filter(files, &is_markdown/1) |> Enum.at 0
		content_html = attrs["content"] |> Kernel.bitstring_to_list 
						|> :erlmarkdown.conv 
						|> Kernel.list_to_bitstring

		html = [:code.priv_dir(:gistsio), "templates", "base.html.eex"]
				|> Path.join
				|> EEx.eval_file [content: content_html]

		{html, req, gist}
	end

	defp is_markdown({_name, attrs}) do
		attrs["language"] === "Markdown"
	end
end