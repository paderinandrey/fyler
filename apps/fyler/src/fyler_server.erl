%% Copyright
-module(fyler_server).
-author("palkan").
-include("../include/log.hrl").
-include("fyler.hrl").

-behaviour(gen_server).

-define(TRY_NEXT_TIMEOUT, 1500).

%% Maximum time for waiting any pool to become enabled.
-define(IDLE_TIME_WM, 60000).

%% Limit on queue length. If it exceeds new pool instance should be started.
-define(QUEUE_LENGTH_WM, 30).

-define(APPS, [ranch, cowlib, cowboy, mimetypes, ibrowse]).

%% API
-export([start_link/0]).

-export([run_task/3, clear_stats/0, send_response/3]).

%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).


-record(pool, {
  node :: atom(),
  enabled :: boolean(),
  active_tasks_num :: non_neg_integer()
}).

%% API
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% gen_server callbacks
-record(state, {
  cowboy_pid :: pid(),
  storage_dir :: string(),
  aws_bucket :: string(),
  pools_active = [] :: list(),
  pools_busy = [] :: list(),
  busy_timer_ref = undefined,
  tasks = queue:new() :: queue()
}).

init(_Args) ->

  net_kernel:monitor_nodes(true),

  ulitos_app:ensure_started(?APPS),

  ?D("Starting fyler webserver"),

  Dir = ?Config(storage_dir, "ff"),

  ets:new(?T_STATS, [bag, public, named_table]),

  {ok, Http} = start_http_server(),

  Bucket = ?Config(aws_s3_bucket, undefined),

  {ok, #state{cowboy_pid = Http, storage_dir = Dir ++ "/", aws_bucket = Bucket}}.


%% @doc
%% Remove all records from statistics ets.
%% @end

-spec clear_stats() -> true.

clear_stats() ->
  ets:delete_all_objects(?T_STATS).


%% @doc
%% Run new task.
%% @end

-spec run_task(string(), string(), list()) -> ok|false.

run_task(URL, Type, Options) ->
  gen_server:call(?MODULE, {run_task, URL, Type, Options}).

handle_call({run_task, URL, Type, Options}, _From, #state{tasks = Tasks, storage_dir = Dir, aws_bucket = Bucket} = State) ->
  case parse_url(URL, Bucket) of
    {IsAws, Path, Name, Ext} ->
      DirId = Dir ++ Name ++ "_" ++ uniqueId(),
      TmpName = DirId ++ "/" ++ Name ++ "." ++ Ext,
      ?D(Options),
      Callback = proplists:get_value(callback, Options, undefined),
      Task = #task{type = list_to_atom(Type), options = Options, callback = Callback, file = #file{extension = Ext, is_aws = IsAws, url = Path, name = Name, dir = DirId, tmp_path = TmpName}},
      NewTasks = queue:in(Task, Tasks),

      self() ! try_next_task,

      {reply, ok, State#state{tasks = NewTasks}};
    _ -> ?D({bad_url, URL}),
      {reply, false, State}
  end;


handle_call(_Request, _From, State) ->
  ?D(_Request),
  {reply, unknown, State}.


handle_cast({pool_enabled,Node,true},#state{pools_busy = Pools} = State) ->
  ?D({pool_enabled,Node}),
  case lists:keyfind(Node,#pool.node,Pools) of
    #pool{}=Pool ->
      self() ! try_next_task,
      {noreply, State#state{pools_busy = lists:keystore(Node,#pool.node,Pools,Pool#pool{enabled = true})}};
    _ -> {noreply,State}
  end;


handle_cast({pool_enabled,Node,false},#state{pools_active = Pools} = State) ->
  ?D({pool_disabled,Node}),
  case lists:keyfind(Node,#pool.node,Pools) of
    #pool{}=Pool ->
      {noreply, State#state{pools_active = lists:keystore(Node,#pool.node,Pools,Pool#pool{enabled = false})}};
    _ -> {noreply,State}
  end;


handle_cast({task_finished,Node},#state{pools_active = Pools, pools_busy = Busy}=State) ->
  {NewPools,NewBusy}= decriment_tasks_num(Pools,Busy,Node),
  {noreply,State#state{pools_active = NewPools,pools_busy = NewBusy}};


handle_cast(_Request, State) ->
  ?D(_Request),
  {noreply, State}.


handle_info({pool_connected, Node, true, Num}, #state{pools_active = Pools} = State) ->
  NewPools = lists:keystore(Node, #pool.node, Pools, #pool{node = Node, active_tasks_num = Num, enabled = true}),
  {fyler_pool, Node} ! pool_accepted,
  {noreply, State#state{pools_active = NewPools}};

handle_info({pool_connected, Node, false, Num}, #state{pools_busy = Pools} = State) ->
  NewPools = lists:keystore(Node, #pool.node, Pools, #pool{node = Node, active_tasks_num = Num, enabled = false}),
  {fyler_pool, Node} ! pool_accepted,
  {noreply, State#state{pools_busy = NewPools}};

handle_info(try_next_task, #state{pools_active = [], busy_timer_ref = undefined} = State) ->
  ?D(<<"All pools are busy; start timer to run new reserved instance">>),
  Ref = erlang:send_after(?IDLE_TIME_WM, self(), alarm_high_idle_time),
  {noreply, State#state{busy_timer_ref = Ref}};

handle_info(try_next_task, #state{pools_active = [], tasks = Tasks} = State) when length(Tasks) > ?QUEUE_LENGTH_WM ->
  ?D({<<"Queue is too big, start new instance">>, length(Tasks)}),
  %%todo:
  {noreply, State};

handle_info(try_next_task, #state{tasks = Tasks, pools_active = Pools} = State) ->
  {NewTasks, NewPools} = case queue:out(Tasks) of
                           {empty, _} -> ?D(no_more_tasks),
                             {Tasks, Pools};
                           {{value, Task}, Tasks2} -> #pool{node = Node, active_tasks_num = Num} = Pool = choose_pool(Pools),
                             rpc:cast(Node, fyler_pool, run_task, [Task]),
                             {Tasks2,lists:keystore(Node,#pool.node,Pools,Pool#pool{active_tasks_num = Num+1})}
                         end,
  Empty = queue:is_empty(NewTasks),
  if Empty
    -> ok;
    true -> erlang:send_after(?TRY_NEXT_TIMEOUT, self(), try_next_task)
  end,
  {noreply, State#state{pools_active = NewPools, tasks = NewTasks}};

handle_info(alarm_high_idle_time, State) ->
  ?D(<<"Too much time in idle state">>),
  %%todo:
  {noreply, State#state{busy_timer_ref = undefined}};

handle_info({nodedown, Node}, #state{pools_active = Pools, pools_busy = Busy} = State) ->
  ?D({nodedown,Node}),
  NewPools = lists:keydelete(Node, #pool.node, Pools),
  NewBusy = lists:keydelete(Node, #pool.node, Busy),
  {noreply, State#state{pools_active = NewPools, pools_busy = NewBusy}};

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

-spec send_response(task(), stats(), success|failed) -> ok|list()|binary().

send_response(#task{callback = undefined}, _, _) ->
  ok;


send_response(#task{callback = Callback, file = #file{is_aws = AWS}}, #job_stats{result_path = Path}, success) ->
  ibrowse:send_req(binary_to_list(Callback), [], post, "status=ok&aws=" ++ atom_to_list(AWS) ++ "&data=" ++ jiffy:encode({[{path, Path}]}), []);

send_response(#task{callback = Callback}, _, failed) ->
  ibrowse:send_req(binary_to_list(Callback), [], post, "status=failed", []).


start_http_server() ->

  Static = fun(Filetype) ->
    {lists:append(["/", Filetype, "/[...]"]), cowboy_static, [
      {directory, {priv_dir, fyler, [list_to_binary(Filetype)]}},
      {mimetypes, {fun mimetypes:path_to_mimes/2, default}}
    ]}
  end,

  Dispatch = cowboy_router:compile([
    {'_', [
      Static("css"),
      Static("js"),
      Static("img"),
      {"/", index_handler, []},
      {"/stats", stats_handler, []},
      {"/api/tasks", task_handler, []},
      {"/api/call/:call", call_handler, []},
      {"/loopback", loopback_handler, []},
      {'_', notfound_handler, []}
    ]}
  ]),
  Port = ?Config(http_port, 8008),
  cowboy:start_http(http_listener, 100,
    [{port, Port}],
    [{env, [{dispatch, Dispatch}]}]
  ).



%% @doc
%% Simply choose pool with the least number of active tasks.
%%
%% todo: more intelligent logic)
%% @end

-spec choose_pool(list(#pool{})) -> #pool{}.

choose_pool(Pools) ->
  hd(lists:keysort(#pool.active_tasks_num,Pools)).



-spec decriment_tasks_num(list(#pool{}),list(#pool{}),atom()) -> {list(#pool{}),list(#pool{})}.

decriment_tasks_num([],[],_Node) ->
  {[],[]};

decriment_tasks_num(A,[],Node) ->
  case lists:keyfind(Node,#pool.node,A) of
    #pool{active_tasks_num = N} = Pool when N>0 -> {lists:keystore(Node,#pool.node,A,Pool#pool{active_tasks_num = N-1}),[]};
    _ -> {A,[]}
  end;

decriment_tasks_num([],A,Node) ->
  case lists:keyfind(Node,#pool.node,A) of
    #pool{active_tasks_num = N} = Pool when N>0 -> {[],lists:keystore(Node,#pool.node,A,Pool#pool{active_tasks_num = N-1})};
    _ -> {[],A}
  end;

decriment_tasks_num(A,B,Node) ->
  case lists:keyfind(Node,#pool.node,A) of
    #pool{active_tasks_num = N} = Pool when N>0 -> {lists:keystore(Node,#pool.node,A,Pool#pool{active_tasks_num = N-1}),B};
    #pool{active_tasks_num = 0} -> {A,B};
    _ -> case lists:keyfind(Node,#pool.node,B) of
           #pool{active_tasks_num = N}=Pool when N>0 -> {A,lists:keystore(Node,#pool.node,B,Pool#pool{active_tasks_num = N-1})};
           _ -> {A,B}
         end
  end.


parse_url(Path, Bucket) ->
  {ok, Re} = re:compile("[^:]+://.+/([^/]+)\\.([^\\.]+)"),
  case re:run(Path, Re, [{capture, all, list}]) of
    {match, [_, Name, Ext]} ->
      {ok, Re2} = re:compile("[^:]+://s3\\-[^\\.]+\\.amazonaws\\.com/([^/]+)/(.+)"),
      case re:run(Path, Re2, [{capture, all, list}]) of
        {match, [_, Bucket, Path2]} -> {true, Bucket ++ "/" ++ Path2, Name, Ext};
        _ -> {false, Path, Name, Ext}
      end;
    _ ->
      false
  end.

-spec uniqueId() -> string().

uniqueId() ->
  {Mega, S, Micro} = erlang:now(),
  integer_to_list(Mega * 1000000000000 + S * 1000000 + Micro).



-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").


path_to_test() ->
  ?assertEqual({false, "http://qwe/data.ext", "data", "ext"}, parse_url("http://qwe/data.ext", [])),
  ?assertEqual({false, "http://dev2.teachbase.ru/app/cpi.txt", "cpi", "txt"}, parse_url("http://dev2.teachbase.ru/app/cpi.txt", [])),
  ?assertEqual({false, "https://qwe/qwe/qwr/da.ta.ext", "da.ta", "ext"}, parse_url("https://qwe/qwe/qwr/da.ta.ext", [])),
  ?assertEqual({true, "qwe/da.ta.ext", "da.ta", "ext"}, parse_url("http://s3-eu-west-1.amazonaws.com/qwe/da.ta.ext", "qwe")),
  ?assertEqual({true, "qwe/path/to/object/da.ta.ext", "da.ta", "ext"}, parse_url("http://s3-eu-west-1.amazonaws.com/qwe/path/to/object/da.ta.ext", "qwe")),
  ?assertEqual({false, "http://s3-eu-west-1.amazonaws.com/qwe/path/to/object/da.ta.ext", "da.ta", "ext"}, parse_url("http://s3-eu-west-1.amazonaws.com/qwe/path/to/object/da.ta.ext", "q")),
  ?assertEqual(false, parse_url("qwr/data.ext", [])).


decr_num_test() ->
  A = [
    #pool{node = a, active_tasks_num = 2},
    #pool{node = b, active_tasks_num = 0}
      ],
  A1 = [
    #pool{node = a, active_tasks_num = 1},
    #pool{node = b, active_tasks_num = 0}
  ],
  B =[
    #pool{node = c, active_tasks_num = 4}
  ],
  B1 =[
    #pool{node = c, active_tasks_num = 3}
  ],

  ?assertEqual({A1,B},decriment_tasks_num(A,B,a)),
  ?assertEqual({A,B1},decriment_tasks_num(A,B,c)),
  ?assertEqual({A,[]},decriment_tasks_num(A,[],c)),
  ?assertEqual({[],[]},decriment_tasks_num([],[],a)),
  ?assertEqual({[],B1},decriment_tasks_num([],B,c)),
  ?assertEqual({A,B},decriment_tasks_num(A,B,b)).



choose_pool_test() ->
  Pool = #pool{node = a, active_tasks_num = 0},
  A = [
    #pool{node = a, active_tasks_num = 2},
    Pool
  ],
  ?assertEqual(Pool, choose_pool(A)).


-endif.
