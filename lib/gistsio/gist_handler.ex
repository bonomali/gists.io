defmodule GistsIO.GistHandler do
	alias :cowboy_req, as: Req
	alias GistsIO.GistClient, as: Gist
	alias GistsIO.Utils
	alias GistsIO.Cache
	require EEx
	require Lager

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
		case Req.binding :gist, req do
			{:undefined, req} -> {:false, req, :index}
			{gist_id, req} ->
				gist_id = :erlang.integer_to_binary(gist_id) 
				client = Session.get("gist_client", req)
				case Cache.get_gist gist_id, client do
					{:error, _} -> {:false, req, gist_id}
					{:ok, gist} ->
						case Req.binding :username, req do
							{:undefined, req} ->
								username = gist["user"]["login"]
								{:false, req, {:redirect, "/#{username}/#{gist_id}"}}
							{username, req} ->
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
	end

	def previously_existed(req, {:redirect, path}) do
		{:true, req, {:redirect, path}}
	end

	def moved_permanently(req, {:redirect, path}) do
		{{:true, path}, req, path}
	end

	def content_types_accepted(req, state) do
  		{[
  			{{"application", "x-www-form-urlencoded", []}, :gist_post}
  		], req, state}
  	end

  	def gist_post(req, {[_, _,"delete"], gist}) do
  		client = Session.get("gist_client", req)
  		Gist.delete_gist client, gist["id"]
  		username = gist["user"]["login"]
  		Cache.remove_gist(username, gist["id"])
  		{{true, "/#{username}"}, req, gist}
  	end

  	def gist_post(req, {[_, _,"comments"],gist}) do
  		client = Session.get("gist_client", req)
  		{:ok, body, req} = Req.body_qs(req)
  		{:ok, response} = Gist.create_comment client, gist["id"], body["comment"]

  		new_comment = Jsonex.decode(response)
  		Cache.add_comment(new_comment, gist["id"])

        prev_path = Session.get("previous_path", req)
  		{{true,prev_path}, req, gist}
  	end

  	def gist_post(req, {path_parts,gist}) do
  		client = Session.get("gist_client", req)
  		{:ok, body, req} = Req.body_qs(req)
  		teaser = body["teaser"]
  		title = body["title"]
  		description = "#{title}\n#{teaser}"
  		new_filename = "#{Regex.replace(%r/ /, title, "_")}.md"
  		{old_filename, old_file} = Enum.find(gist["files"], &Utils.is_markdown/1)
		files = [{old_filename, [{"filename", new_filename},{"content",body["content"]}]}]
  		Gist.edit_gist client, gist["id"], description, files
  		Cache.update_gist(description, files, gist)

  		prev_path = Session.get("previous_path", req)
  		{{true,prev_path}, req, gist}
  	end

	def gist_html(req, {path_parts,gist}) do
		client = Session.get("gist_client", req)
		loggedin = case Session.get("is_loggedin", req) do
			:undefined -> false
			result -> result
		end
		{:ok, html} = if :application.get_env(:gistsio, :use_static_page, false) do
			maybe_render_template(gist, loggedin, client)
		else
			render(gist, loggedin, client)
		end
		{html, req, gist}
	end

	defp maybe_render_template(gist, loggedin?, client) do
		username = gist["user"]["login"]
		gist_id = gist["id"]
		{dir, html_path} = html_path(username, gist_id)
		# Check the time the cache is created
		modified_at = Cache.gist_last_updated(username, gist_id)
						|> :calendar.gregorian_seconds_to_datetime()
		generated_at = :filelib.last_modified(html_path)

		case modified_at > generated_at do
			true ->
				# The cache is newer than the static file, we render it again.
				Lager.debug "Rendering HTML for gist #{gist_id} of user #{username}"
				{:ok, html} = render(gist, loggedin?, client)
				File.mkdir_p(dir) # Ensure the directory is created
				File.write(html_path, html)
				{:ok, html}
			false ->
				# Cache is older, just serve the static file.
				Lager.debug "Serving static HTML for gist #{gist_id} of user #{username}"
				File.read(html_path)
		end
	end

	defp render(gist, loggedin?, client) do
		files = gist["files"]
		gist_id = gist["id"]
		{name, attrs} = Enum.find(files, &Utils.is_markdown/1)
		{:ok, comments} = Cache.get_comments gist_id, client
		{:ok, comments_html} = Enum.reduce(comments, "", fn(comment, acc) ->
			username = comment["user"]["login"]
			acc <> "<div class=\"comment-author\">\n"
			<> "<a href=\"/" <> username <> "\" target=\"_blank\">"
			<> "<img src=\"" <> comment["user"]["avatar_url"] <> "\" alt=\"" <> username <>"\" class=\"img-circle comment-author-avatar\" />"
			<> "</a>\n"
			<> "<a href=\"/" <> username <> "\" target=\"_blank\"><span class=\"comment-author-name\">" <> username <> "</span></a>\n"
			<> "<span class=\"comment-time\">" <> comment["updated_at"] <> "</span>"
			<> "</div>\n\n" 
			<> to_blockquote(comment["body"]) <> "\n"
		end) |> Cache.get_html(client)

		# Acquire embed code for each file other than the main file
		attachments = lc {n, _} inlist files, n !== name, do: {n, embed(gist, n)}
		# Parse the Markdown into HTML, then evaluate any <%= files[filename] %> tag
		# and replace with the corresponding embed code.
		# This way the author can embed any file in his/her gist any where in the article.
		{:ok, entry_html} = Cache.get_html(attrs["content"], client)
		entry_html = Regex.replace(%r/&lt;/, entry_html, "<")
		entry_html = Regex.replace(%r/&gt;/, entry_html, ">")
					|> EEx.eval_string [files: attachments] # allow inline embed

		# Then set up article's title using either the description or filename
		gist = gist |> Utils.prep_gist 
					|> ListDict.put("html", entry_html)
					|> ListDict.put("attachments", attachments)

		comments_html = [:code.priv_dir(:gistsio), "templates", "comments.html.eex"]
				|> Path.join
				|> EEx.eval_file [gist_id: gist_id, html: comments_html, is_loggedin: loggedin?]

		# Render the gist's partial
		gist_html = [:code.priv_dir(:gistsio), "templates", "gist.html.eex"]
				|> Path.join
				|> EEx.eval_file [entry: gist, comments: comments_html, is_loggedin: loggedin?]

		# Render author's info on the sidebar
		{:ok, user} = Cache.get_user gist["user"]["login"], client
		sidebar_html = [:code.priv_dir(:gistsio), "templates", "sidebar.html.eex"]
				|> Path.join
				|> EEx.eval_file [user: user]

		# Put it into the base layout
		html = [:code.priv_dir(:gistsio), "templates", "base.html.eex"]
				|> Path.join
				|> EEx.eval_file [content: gist_html, 
									title: gist["title"],
									sidebar: sidebar_html,
									is_loggedin: loggedin?]
		{:ok, html}
	end

	defp html_path(username, gist_id) do
		{:ok, cwd} = File.cwd()
		dir = :filename.join([cwd, "priv", "static", username])
		{dir, :filename.join([dir, "gist_#{gist_id}.html"])}
	end

	defp to_blockquote(markdown) when is_binary(markdown) do
		to_blockquote(:binary.split(markdown, "\n", [:global]))
	end
	defp to_blockquote([]) do "" end
	defp to_blockquote([line | rest]) do
		rest = to_blockquote(rest)
		<<"> ", line :: binary, "\n", rest :: binary >>
	end

	# defp to_bq(markdown) do
	# 	markdown = <<"> ", markdown :: binary>>
	# 	bc <<c>> inbits markdown do
	# 		if c == ?\n do
	# 			<<"\n> ">>
	# 		else
	# 			<<c>>
	# 		end
	# 	end
	# end

	defp embed(gist, filename) do
		[:code.priv_dir(:gistsio), "templates", "embed.html.eex"]
		|> Path.join
		|> EEx.eval_file [gist: gist, name: filename]
	end
end