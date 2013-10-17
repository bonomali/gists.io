defmodule GistsIO.GistHandler do
	alias :cowboy_req, as: Req
	alias GistsIO.GistClient, as: Gist
	alias GistsIO.Utils, as: Utils
	require EEx

	def init(_transport, _req, []) do
		{:upgrade, :protocol, :cowboy_rest}
	end

	def allowed_methods(req, state) do
		{["GET","POST"], req, state}
	end

	def content_types_provided(req, state) do
		{[
			{"text/html", :gist_html}
		], req, state}
	end

	def resource_exists(req, _state) do
		# @TODO: Check if binding has username, and redirect if not the right one
		case Req.binding :gist, req do
			{:undefined, req} -> {:false, req, :index}
			{gist_id, req} -> 
				client = Session.get("gist_client", req)
				case Gist.fetch_gist client, gist_id do
					{:error, _} -> {:false, req, gist_id}
					{:ok, gist} ->
						files = gist["files"]
						if files !== nil and Enum.any?(files, &Utils.is_markdown/1) do
							{path,req} = Req.path(req)
							[""|path_parts] = Regex.split(%r/\//, path)
							{:true, req, {path_parts,gist}}
						else
							{:false, req, gist}
						end
				end	
		end
	end

	def content_types_accepted(req, state) do
  		{[
  			{{"application", "x-www-form-urlencoded", []}, :gist_post}
  		], req, state}
  	end

  	def gist_post(req, {[_,"delete"], gist}) do
  		client = Session.get("gist_client", req)
  		Gist.delete_gist client, gist["id"]
  		{{true, "/#{gist["user"]["login"]}"}, req, gist}
  	end

  	def gist_post(req, {[_,"comments"],gist}) do
  		client = Session.get("gist_client", req)
  		{:ok, body, req} = Req.body_qs(req)
  		Gist.create_comment client, gist["id"], body["comment"]
        prev_path = Session.get("previous_path", req)
  		{{true,prev_path}, req, gist}
  	end

  	def gist_post(req, {path_parts,gist}) do
  		client = Session.get("gist_client", req)
  		{:ok, body, req} = Req.body_qs(req)
  		teaser = body["teaser"]
  		title = body["title"]
  		{old_title,_} = Utils.parse_description(gist)
  		description = "#{title}\n#{teaser}"
  		new_filename = "#{Regex.replace(%r/ /, title, "_")}.md"
  		old_filename = "#{Regex.replace(%r/ /, old_title, "_")}.md"

		files = [{old_filename, [{"filename", new_filename},{"content",body["content"]}]}]
  		Gist.edit_gist client, gist["id"], description, files
  		prev_path = Session.get("previous_path", req)
  		{{true,prev_path}, req, gist}
  	end

	def gist_html(req, {path_parts,gist}) do
		client = Session.get("gist_client", req)
		files = gist["files"]
		{name, attrs} = Enum.filter(files, &Utils.is_markdown/1) |> Enum.at 0

		{:ok, comments} = Gist.fetch_comments client, gist["id"]
		# Append comments' Markdown with gist's content and send to render
		# in one go. Separated by some indicators so we can tell.
		entry = Enum.reduce(comments, attrs["content"] <> "\n- - -\n", fn(comment, acc) ->
			acc  <> "\n\n&lt;span class=\"commenter\"&gt;" 
				<> comment["user"]["login"] 
				<> "&lt;/span&gt; commented on " 
				<> comment["created_at"] 
				<> ":\n" <> comment["body"]
		end)

		loggedin = case Session.get("is_loggedin", req) do
			:undefined -> false
			result -> result
		end

		# Acquire embed code for each file other than the main file
		attachments = lc {n, _} inlist files, n !== name, do: {n, embed(gist, n)}
		# Parse the Markdown into HTML, then evaluate any <%= files[filename] %> tag
		# and replace with the corresponding embed code.
		# This way the author can embed any file in his/her gist any where in the article.
		{:ok, markdown_html} = Gist.render client, entry
		markdown_html = Regex.replace(%r/&lt;/, markdown_html, "<")
		markdown_html = Regex.replace(%r/&gt;/, markdown_html, ">")
					|> EEx.eval_string [files: attachments] # allow inline embed

		# Then set up article's title using either the description or filename
		gist = gist |> Utils.prep_gist 
					|> ListDict.put("html", markdown_html)
					|> ListDict.put("attachments", attachments)
		# Render the gist's partial
		gist_html = [:code.priv_dir(:gistsio), "templates", "gist.html.eex"]
				|> Path.join
				|> EEx.eval_file [entry: gist,
									is_loggedin: loggedin]

		# Render author's info on the sidebar
		{:ok, user} = Gist.fetch_user client, gist["user"]["login"]
		sidebar_html = [:code.priv_dir(:gistsio), "templates", "sidebar.html.eex"]
				|> Path.join
				|> EEx.eval_file [user: user]

		# Put it into the base layout
		html = [:code.priv_dir(:gistsio), "templates", "base.html.eex"]
				|> Path.join
				|> EEx.eval_file [content: gist_html, 
									title: gist["title"],
									sidebar: sidebar_html,
									is_loggedin: loggedin]

		{html, req, gist}
	end

	defp embed(gist, filename) do
		[:code.priv_dir(:gistsio), "templates", "embed.html.eex"]
		|> Path.join
		|> EEx.eval_file [gist: gist, name: filename]
	end
end