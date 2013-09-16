%% Copyright
-module(fyler_server).
-author("palkan").
-include("../include/log.hrl").
-include("fyler.hrl").

-behaviour(gen_server).

-define(TRY_NEXT_TIMEOUT, 1500).

%% API
-export([start_link/0]).

-export([run_task/3, disable/0, enable/0, send_response/3]).

%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

%% API
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% gen_server callbacks
-record(state, {
  enabled = true :: boolean(),
  cowboy_pid :: pid(),
  listener :: pid(),
  storage_dir :: string(),
  tasks = queue:new() :: queue(),
  active_tasks = [] :: list(task())
}).

init(_Args) ->
  ?D("Starting fyler webserver"),
  Dir = ?Config(storage_dir, "tmp"),
  filelib:ensure_dir(Dir),

  {ok, Http} = start_http_server(),

  {ok, Events} = start_event_listener(),

  {ok, #state{cowboy_pid = Http, listener = Events, storage_dir = Dir}}.


%% @doc
%% Run new task.
%% @end

-spec run_task(string(), string(), list()) -> ok|false.

run_task(URL, Type, Options) ->
  gen_server:call(?MODULE, {run_task, URL, Type, Options}).

%% @doc
%% Stop running tasks and queue them.
%% @end

-spec disable() -> ok|false.

disable() ->
  gen_server:call(?MODULE, {enabled, false}).

%% @doc
%% Enable running tasks and run tasks from queue.
%% @end

-spec enable() -> ok|false.

enable() ->
  gen_server:call(?MODULE, {enabled, true}).


handle_call({run_task, URL, Type, Options}, _From, #state{enabled = Enabled, tasks = Tasks, storage_dir = Dir} = State) ->
  case path_to_name_ext(URL) of
    {Name, Ext} ->
      DirId = Dir ++ Name ++ "_" ++ uniqueId(),
      ok = file:make_dir(DirId),
      TmpName = DirId ++ "/" ++ Name ++ "." ++ Ext,
      Callback = proplists:get_value(callback,Options,undefined),
      Task = #task{type = list_to_atom(Type), options = Options, callback = Callback, file = #file{extension = Ext, url = URL, name = Name, dir = DirId,  tmp_path = TmpName}},
      NewTasks = queue:in(Task, Tasks),
      if Enabled
        -> self() ! next_task;
        true -> ok
      end,
      {reply, ok, State#state{tasks = NewTasks}};
    _ -> ?D({bad_url, URL}),
      {reply, false, State}
  end;

handle_call({enabled, true}, _From, #state{enabled = false} = State) ->
  self() ! next_task,
  erlang:send_after(?TRY_NEXT_TIMEOUT,self(),try_next_task),
  {reply, ok, State#state{enabled = true}};

handle_call({enabled, false}, _From, #state{enabled = true} = State) ->
  {reply, ok, State#state{enabled = false}};

handle_call({enabled, true}, _From, #state{enabled = true} = State) -> {reply, false, State};
handle_call({enabled, false}, _From, #state{enabled = false} = State) -> {reply, false, State};


handle_call(_Request, _From, State) ->
  ?D(_Request),
  {reply, unknown, State}.

handle_cast(_Request, State) ->
  ?D(_Request),
  {noreply, State}.


handle_info(next_task, #state{tasks = Tasks, active_tasks = Active} = State) ->
  {NewTasks, NewActive} = case queue:out(Tasks) of
                            {empty, _} -> fyler_monitor:stop_monitor(),
                              {Tasks, Active};
                            {{value, Task}, Tasks2} -> fyler_monitor:start_monitor(),
                              {ok, Pid} = fyler_sup:start_worker(Task),
                              Ref = erlang:monitor(process, Pid),
                              Active2 = lists:keystore(Ref, #task.worker, Active, Task#task{worker = Ref}),
                              {Tasks2, Active2}
                          end,
  {noreply, State#state{active_tasks = NewActive, tasks = NewTasks}};


handle_info(try_next_task, #state{enabled = false} = State) ->
  {noreply,State};

handle_info(try_next_task, #state{tasks = Tasks} = State) ->
  Empty = queue:is_empty(Tasks),
  if Empty
    -> ok;
    true -> self() ! next_task,
            erlang:send_after(?TRY_NEXT_TIMEOUT,self(),try_next_task)
  end,
  {noreply,State};


handle_info({'DOWN', Ref, process, _Pid, normal}, #state{enabled = Enabled, active_tasks = Active} = State) ->
  NewActive = case lists:keyfind(Ref, #task.worker, Active) of
               #task{} -> lists:keydelete(Ref, #task.worker, Active);
               _ -> Active
             end,
  if Enabled
    -> self() ! next_task;
    true -> ok
  end,
  {noreply, State#state{active_tasks = NewActive}};

handle_info({'DOWN', Ref, process, _Pid, Other}, #state{enabled = Enabled, active_tasks = Active} = State) ->
  NewActive = case lists:keyfind(Ref, #task.worker, Active) of
                #task{} = Task ->  fyler_event:task_failed(Task,Other),
                            lists:keydelete(Ref, #task.worker, Active);
                _ -> Active
              end,
  if Enabled
    -> self() ! next_task;
    true -> ok
  end,
  {noreply, State#state{active_tasks = NewActive}};


handle_info(Info, State) ->
  ?D(Info),
  {noreply, State}.

terminate(_Reason, _State) ->
  ?D(_Reason),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


%% @doc
%% Send response to task initiator as HTTP Post with params <code>status = success|failed</code> and <code>path</code - path to download file if success.
%% @end

-spec send_response(task(),stats(),success|failed) -> ok|list()|binary().

send_response(#task{callback = undefined},_,_) ->
  ok;

send_response(#task{callback = Callback},#job_stats{result_path = Path},success) ->
  ibrowse:send_req(Callback,[],post,[{status,ok},{path,Path}],[]);

send_response(#task{callback = Callback},_,failed) ->
  ibrowse:send_req(Callback,[],post,[{status,failed}],[]).


start_http_server() ->
  Dispatch = cowboy_router:compile([
    {'_', [
      {"/file/[...]", cowboy_static, [
        {directory, <<"tmp">>},
        {mimetypes, {fun mimetypes:path_to_mimes/2, default}}
      ]},
      {"/", index_handler, []},
      {"/api/tasks", task_handler, []},
      {'_', notfound_handler, []}
    ]}
  ]),
  Port = ?Config(http_port, 8008),
  cowboy:start_http(http_listener, 100,
    [{port, Port}],
    [{env, [{dispatch, Dispatch}]}]
  ).


start_event_listener() ->
  ?D(start_event_listener),
  Pid = spawn_link(fyler_event_listener, listen, []),
  {ok, Pid}.

path_to_name_ext(Path) ->
  {ok, Re} = re:compile("[^:]+://.+/([^/]+)\\.([^\\.]+)"),
  case re:run(Path, Re, [{capture, all, list}]) of
    {match, [_, Name, Ext]} ->
      {Name, Ext};
    _ ->
      false
  end.

-spec uniqueId() -> string().

uniqueId() ->
  {Mega,S,Micro} = erlang:now(),
  integer_to_list(Mega*1000000000000+S*1000000+Micro).



-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").


path_to_test() ->
  ?assertEqual({"data", "ext"}, path_to_name_ext("http://qwe/data.ext")),
  ?assertEqual({"cpi", "txt"}, path_to_name_ext("http://dev2.teachbase.ru/app/cpi.txt")),
  ?assertEqual({"da.ta", "ext"}, path_to_name_ext("http://qwe/qwe/qwr/da.ta.ext")),
  ?assertEqual(false, path_to_name_ext("qwr/data.ext")).

-endif.
