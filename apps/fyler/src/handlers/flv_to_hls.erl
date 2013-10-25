%%% @doc Module handling generating swfs from pdf
%%% @end

-module(flv_to_hls).
-include("../fyler.hrl").
-include("../../include/log.hrl").

-export([run/1, run/2]).

-define(COMMAND(In,Out),
  "ffmpeg -i "++In++" -c:v libx264 -g 15 -keyint_min 15 -c:a libfaac -ac 2 -ar 48000 -ab 192k -profile:v baseline -hls_time 10 -hls_list_size 999 "++Out).

-define(COMMAND2(In,Out),
  "ffmpeg -i "++In++" -c:v libx264 -g 2 -keyint_min 2 -an -profile:v baseline -hls_time 10 -hls_list_size 999 "++Out).

run(File) -> run(File,[]).

run(#file{tmp_path = Path, name = Name, dir = Dir},Opts) ->
  Start = ulitos:timestamp(),
  M3U = Dir++"/"++Name++".m3u8",
  Command = case proplists:get_value(stream_type,Opts,false) of
    <<"share">> -> ?COMMAND2(Path,M3U);
              _ -> ?COMMAND(Path,M3U)
  end,
  ?D({"command",Command}),
  Data = os:cmd(Command),
  case filelib:wildcard("*.m3u8",Dir) of
    [] -> {error,Data};
    _List ->
      Result = Name++".m3u8",
      {ok,#job_stats{time_spent = ulitos:timestamp() - Start, result_path = [list_to_binary(Result)]}}
  end.







