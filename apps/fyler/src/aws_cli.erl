%% Copyright
-module(aws_cli).
-author("palkan").

-include("../include/log.hrl").

-define(NOT_EXISTS_SIZE,87).

%% API
-export([copy_object/2, copy_object/3, copy_folder/2, copy_folder/3, dir_exists/1]).


copy_object(From,To) ->
  copy_object(From,To,public).

-spec copy_object(string(),string(),any()) -> any().
copy_object(From,To,Acl) ->
  os:cmd(io_lib:format("aws s3 cp --acl ~s ~s ~s",[access_to_acl(Acl),From,To])).

copy_folder(From,To) ->
  copy_folder(From,To,public).

-spec copy_folder(string(),string(),any()) -> any().
copy_folder(From,To,Acl) ->
  os:cmd(io_lib:format("aws s3 sync --acl ~s ~s ~s",[access_to_acl(Acl),From,To])).

%% @doc
%% Check whether s3 dir prefix exists.
%%
%% <b>Note</b>: don't forget about tailing slash;
%% Algorithm is empirical, but works fine.
%% @end

-spec dir_exists(Path::list()) -> boolean().

dir_exists(Path) ->
  Res = os:cmd("aws s3 ls "++Path),
  length(Res)-length(Path) > ?NOT_EXISTS_SIZE.


access_to_acl(private) ->
  "private";

access_to_acl(public) ->
  "public-read";

access_to_acl(authorized) ->
  "authenticated-read";

access_to_acl(_) ->
  "public".