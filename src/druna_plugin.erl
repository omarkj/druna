-module(druna_plugin).

-export([preprocess/2,
	 'get-deps'/2,
	 'delete-deps'/2,
	 'list-deps'/2,
	 'make-druna'/2]).

-record(druna_dep, {app_name :: atom()|undefined,
		    app_vsn :: iolist(),
		    server :: iolist()|undefined,
		    folder :: filename:file(),
		    downloaded = false :: boolean(),
		    username :: undefined|iolist(),
		    password :: undefined|iolist()
		   }).

preprocess(Config, _AppFile) ->
    AvailableDepsPaths = [ Folder || #druna_dep{folder = Folder,
						downloaded = true}
					 <- get_druna_deps(Config)],
    update_deps_code_path(AvailableDepsPaths),
    % Not going to return a list of deps here, I don't want clean
    % run on it.
    {ok, Config, AvailableDepsPaths}.

'get-deps'(Config, _AppFile) ->
    application:start(inets),
    application:start(public_key),
    application:start(crypto),
    application:start(ssl),
    DrunaDeps = get_druna_deps(Config),
    TmpDir = create_temp_dir(),
    ensure_deps_dir(Config),
    download_deps(DrunaDeps, TmpDir),
    {ok, save_deps_dirs(Config)}.

save_deps_dirs(Config) ->
    DepsDir = [ Folder || #druna_dep{folder = Folder,
				     downloaded = true}
			      <- get_druna_deps(Config)],
    rebar_config:set_xconf(Config, rebar_deps, DepsDir).

'list-deps'(Config, _AppFile) ->
    DrunaDeps = get_druna_deps(Config),
    lists:foreach(fun(#druna_dep{app_name = AppName,
				 app_vsn = AppVsn,
				 downloaded = Downloaded}) ->
			  io:format("DRUNA: Package ~p (~s), downloaded: ~p", [AppName,
									       AppVsn,
									       Downloaded])
		  end, DrunaDeps),
    ok.

'delete-deps'(Config, _AppFile) ->
    DrunaDeps = get_druna_deps(Config),
    delete_deps(DrunaDeps),
    ok.

'make-druna'(Config, _AppFile) ->
    % Try to find an app file in ebin
    AppFileWildcard = filename:join(["ebin", "*.app"]),
    case filelib:wildcard(AppFileWildcard) of
	[AppFile] ->
	    {ok, [App]} = file:consult(AppFile),
	    package(Config, App),
	    ok;
	_ ->
	    rebar_log:log(error, "DRUNA: No app file found", [])
    end,
    ok.

%% Internal
package(_Config, {application, AppName, Info}) ->
    Version = proplists:get_value(vsn, Info),
    PackageName = string:join([atom_to_list(AppName), Version], "-"),
    file:make_dir(PackageName),
    rebar_file_utils:cp_r(["ebin"], filename:join([PackageName, "ebin"])),
    case filelib:is_dir("include") of
	true ->
	    rebar_file_utils:cp_r(["include"], filename:join([PackageName, "include"]));
	_ ->
	    ok
    end,
    case filelib:is_dir("priv") of
	true ->
	    rebar_file_utils:cp_r(["priv"], filename:join([PackageName, "priv"]));
	_ ->
	    ok
    end,
    case filelib:is_file("rebar.config") of %% @TODO just copy the needed stuff from here
	true ->
	    rebar_file_utils:cp_r(["rebar.config"], filename:join([PackageName, "rebar.config"]));
	_ ->
	    ok
    end,
    zip:create(string:join([PackageName, "ez"], "."),
	       [PackageName], [{compress, all},
			       {uncompress, [".beam", ".app"]}]),
    rebar_file_utils:rm_rf(PackageName),
    io:format("DRUNA: Created ~s~n", [PackageName]).


delete_deps([]) ->
    ok;
delete_deps([#druna_dep{folder = Folder}|Rest]) ->
    rebar_file_utils:rm_rf(Folder),
    delete_deps(Rest).

get_druna_deps(RebarConfig) ->
    DepsDir = get_deps_dir(RebarConfig),
    DrunaConfig = rebar_config:get_local(RebarConfig, druna, []),
    ServerInfo = proplists:get_value(servers, DrunaConfig, []),
    DrunaDeps = proplists:get_value(deps, DrunaConfig, []),
    get_druna_deps(DrunaDeps, ServerInfo, DepsDir, []).

get_druna_deps([], _, _, Retval) ->
    Retval;
get_druna_deps([{AppName, DepsOpts}|Rest], ServerInfo, DepsDir, Retval) ->
    Vsn = proplists:get_value(vsn, DepsOpts, undefined),
    Dep = #druna_dep{app_name = AppName, app_vsn=Vsn},
    Dep0 = case proplists:get_value(server, DepsOpts, undefined) of
	       undefined ->
		   Dep;
	       ServerIdent ->
		   fill_server(Dep, ServerIdent, ServerInfo)
	   end,
    FolderName = filename:join([DepsDir, atom_to_list(AppName)]),
    %% @Todo check if there is an app file in the FolderName?
    Dep1 = Dep0#druna_dep{folder = FolderName,
			  downloaded = filelib:is_dir(FolderName)},
    get_druna_deps(Rest, ServerInfo, DepsDir, Retval ++ [Dep1]).

fill_server(Dep, ServerIdent, ServerInfo) ->
    Server = proplists:get_value(ServerIdent, ServerInfo, undefined),
    ServerUrl = proplists:get_value(url, Server, undefined),
    Dep#druna_dep{server = ServerUrl,
		  username = proplists:get_value(username, Server),
		  password = proplists:get_value(password, Server)}.

download_deps([], TmpDir) ->
    file:del_dir(TmpDir),
    ok;
download_deps([#druna_dep{app_name = AppName,
			  folder = Folder,
			  downloaded = true}|Rest], TmpDir) ->
    io:format("DRUNA: Skipping ~p (exists in ~s)~n", [AppName, Folder]),
    download_deps(Rest, TmpDir);
download_deps([#druna_dep{app_name = AppName,
			  app_vsn = AppVsn,
			  server = Server,
			  folder = Folder,
			  downloaded = false,
			  username = Username,
			  password = Password}|Rest], TmpDir) ->
    AppName0 = atom_to_list(AppName),
    Url = create_url(Server, AppName, AppVsn),
    Headers = auth_header(Username, Password),
    ArchiveName = filename:join([TmpDir, "package"]),
    download_package(ArchiveName, AppName0, Url, Headers),
    place_files(TmpDir, Folder),
    download_deps(Rest, TmpDir).

place_files(TmpDir, AppDir) ->
    ArchiveName = filename:join([TmpDir, "package"]),
    {ok, FileList} = zip:unzip(ArchiveName, [{cwd, TmpDir}]),
    [TmpDir, Second|_] = string:tokens(hd(FileList), "/"),
    ok = file:rename(filename:join([TmpDir, Second]), AppDir),
    ok = file:delete(ArchiveName).

download_package(DownloadTo, AppName, Url, Headers) ->
    case head_package(Url, Headers) of
	200 ->
	    io:format("DRUNA: Downloading ~s from ~s~n", [AppName, Url]),
	    httpc:request(get, {Url, Headers}, [],[{stream, DownloadTo},
						   {sync, true}]);
	Code ->
	    rebar_log:log(error, "Unable to download package: Code ~p", [Code]),
	    erlang:error({druna, package_not_found})
    end.

head_package(Url, AuthHeader) ->
    {ok, {{_, Code, _}, _, _}} = httpc:request(head, {Url, AuthHeader}, [], []),
    Code.

auth_header(undefined, _) ->
    [];
auth_header(User, Pass) ->
    Encoded = base64:encode_to_string(lists:append([User,":",Pass])),
    [{"Authorization","Basic " ++ Encoded}].

create_url(Server, AppName, AppVsn) ->
    AppName0 = atom_to_list(AppName),
    PackageName = string:join([AppName0, AppVsn], "-"),
    string:join([Server, PackageName, "download"], "/").

create_temp_dir() ->
    create_temp_dir(integer_to_list(random:uniform(10000))).

ensure_deps_dir(RebarConfig) ->
    DepsDir = get_deps_dir(RebarConfig),
    case filelib:is_dir(DepsDir) of
	true ->
	    ok;
	false ->
	    file:make_dir(DepsDir)
    end.

create_temp_dir(TempName) ->
    case filelib:is_dir(TempName) of
	false ->
	    file:make_dir(TempName),
	    TempName;
	true ->
	    create_temp_dir()
    end.

get_deps_dir(Config) ->
    BaseDir = rebar_config:get_xconf(Config, base_dir, []),
    DepsDir = get_shared_deps_dir(Config, "deps"),
    filename:join([BaseDir, DepsDir]).

get_shared_deps_dir(Config, Default) ->
    rebar_config:get_xconf(Config, deps_dir, Default).

update_deps_code_path([]) ->
    ok;
update_deps_code_path([Dir|Rest]) ->
    true = code:add_patha(filename:join([Dir, "ebin"])),
    update_deps_code_path(Rest).
