%% ---------------------------------------------------------------------
%%
%% Copyright (c) 2007-2013 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% ---------------------------------------------------------------------

-module(riak_cs_block_server).

-behaviour(gen_server).

-include("riak_cs.hrl").
-include_lib("riak_pb/include/riak_pb_kv_codec.hrl").

%% API
-export([start_link/0,
         start_link/1,
         start_block_servers/2,
         get_block/5, get_block/6,
         put_block/6,
         delete_block/5,
         maybe_stop_block_servers/1,
         stop/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).
-define(USERMETA_BUCKET, "RCS-bucket").
-define(USERMETA_KEY,    "RCS-key").
-define(USERMETA_BCSUM,  "RCS-bcsum").

-record(state, {riakc_pid :: pid(),
                close_riak_connection=true :: boolean()}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link(?MODULE, [], []).

start_link(RiakPid) ->
    gen_server:start_link(?MODULE, [RiakPid], []).

%% @doc Start (up to) 'MaxNumServers'
%% riak_cs_block_server procs.
%% 'RiakcPid' must be a Pid you already
%% have for a riakc_pb_socket proc. If the
%% poolboy boy returns full, you will be given
%% a list of less than 'MaxNumServers'.

%% TODO: this doesn't guarantee any minimum
%% number of workers. I could also imagine
%% this function looking something
%% like:
%% start_block_servers(RiakcPid, MinWorkers, MaxWorkers, MinWorkerTimeout)
%% Where the function works something like:
%% Give me between MinWorkers and MaxWorkers,
%% waiting up to MinWorkerTimeout to get at least
%% MinWorkers. If the timeout occurs, this function
%% could return an error, or the pids it has
%% so far (which might be less than MinWorkers).
-spec start_block_servers(pid(), pos_integer()) -> [pid()].
start_block_servers(RiakcPid, 1) ->
    {ok, Pid} = start_link(RiakcPid),
    [Pid];
start_block_servers(RiakcPid, MaxNumServers) ->
    case start_link() of
        {ok, Pid} ->
            [Pid | start_block_servers(RiakcPid, (MaxNumServers - 1))];
        {error, normal} ->
            start_block_servers(RiakcPid, 1)
    end.

-spec get_block(pid(), binary(), binary(), binary(), pos_integer()) -> ok.
get_block(Pid, Bucket, Key, UUID, BlockNumber) ->
    gen_server:cast(Pid, {get_block, self(), Bucket, Key, undefined, UUID, BlockNumber}).

%% @doc get a block which is know to have originated on cluster ClusterID.
%% If it's not found locally, it might get returned from the replication
%% cluster if a connection exists to that cluster. This is proxy-get().
-spec get_block(pid(), binary(), binary(), binary(), binary(), pos_integer()) -> ok.
get_block(Pid, Bucket, Key, ClusterID, UUID, BlockNumber) ->
    gen_server:cast(Pid, {get_block, self(), Bucket, Key, ClusterID, UUID, BlockNumber}).

-spec put_block(pid(), binary(), binary(), binary(), pos_integer(), binary()) -> ok.
put_block(Pid, Bucket, Key, UUID, BlockNumber, Value) ->
    gen_server:cast(Pid, {put_block, self(), Bucket, Key, UUID, BlockNumber, Value, crypto:md5(Value)}).

-spec delete_block(pid(), binary(), binary(), binary(), pos_integer()) -> ok.
delete_block(Pid, Bucket, Key, UUID, BlockNumber) ->
    gen_server:cast(Pid, {delete_block, self(), Bucket, Key, UUID, BlockNumber}).

-spec maybe_stop_block_servers(undefined | [pid()]) -> ok.
maybe_stop_block_servers(undefined) ->
    ok;
maybe_stop_block_servers(BlockServerPids) ->
    _ = [stop(P) || P <- BlockServerPids],
    ok.

stop(Pid) ->
    gen_server:call(Pid, stop, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([RiakPid]) ->
    process_flag(trap_exit, true),
    {ok, #state{riakc_pid=RiakPid,
                close_riak_connection=false}};
init([]) ->
    process_flag(trap_exit, true),
    case riak_cs_utils:riak_connection() of
        {ok, RiakPid} ->
            {ok, #state{riakc_pid=RiakPid}};
        {error, all_workers_busy} ->
            {stop, normal}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_cast({get_block, ReplyPid, Bucket, Key, ClusterID, UUID, BlockNumber}, State=#state{riakc_pid=RiakcPid}) ->
    dt_entry(<<"get_block">>, [BlockNumber], [Bucket, Key]),
    {FullBucket, FullKey} = full_bkey(Bucket, Key, UUID, BlockNumber),
    StartTime = os:timestamp(),
    GetOptions = [{r, 1}, {notfound_ok, false}, {basic_quorum, false}],
    LocalClusterID = riak_cs_utils:get_cluster_id(RiakcPid),
    %% don't use proxy get if it's a local get
    %% or proxy get is disabled
    UseProxyGet = ClusterID /= undefined
                    andalso riak_cs_utils:proxy_get_active()
                    andalso LocalClusterID /= ClusterID,
    Object =
        case UseProxyGet of
            false ->
                riakc_pb_socket:get(RiakcPid, FullBucket, FullKey, GetOptions);
            true ->
                riak_repl_pb_api:get(RiakcPid, FullBucket, FullKey, ClusterID, GetOptions)
        end,
    ChunkValue = case Object of
        {ok, RiakObject} ->
            resolve_block_object(RiakObject, RiakcPid);
            %% %% Corrupted siblings hack: just add another....
            %% [{MD,V}] = riakc_obj:get_contents(RiakObject),
            %% RiakObject2 = setelement(5, RiakObject, [{MD, <<"foobar">>}, {MD, V}]),
            %% resolve_block_object(RiakObject2, RiakcPid);
        {error, notfound}=NotFound ->
            NotFound
    end,
    ok = riak_cs_stats:update_with_start(block_get, StartTime),
    ok = riak_cs_get_fsm:chunk(ReplyPid, {UUID, BlockNumber}, ChunkValue),
    dt_return(<<"get_block">>, [BlockNumber], [Bucket, Key]),
    {noreply, State};
handle_cast({put_block, ReplyPid, Bucket, Key, UUID, BlockNumber, Value, BCSum},
            State=#state{riakc_pid=RiakcPid}) ->
    dt_entry(<<"put_block">>, [BlockNumber], [Bucket, Key]),
    {FullBucket, FullKey} = full_bkey(Bucket, Key, UUID, BlockNumber),
    MD = make_md_usermeta([{?USERMETA_BUCKET, Bucket},
                           {?USERMETA_KEY, Key},
                           {?USERMETA_BCSUM, BCSum}]),
    FailFun = fun(Error) ->
                      lager:error("Put ~p ~p UUID ~p block ~p failed: ~p\n",
                                  [Bucket, Key, UUID, BlockNumber, Error])
              end,
    %% TODO: Handle put failure here.
    ok = do_put_block(FullBucket, FullKey, undefined, Value, MD, RiakcPid, FailFun),
    riak_cs_put_fsm:block_written(ReplyPid, BlockNumber),
    dt_return(<<"put_block">>, [BlockNumber], [Bucket, Key]),
    {noreply, State};
handle_cast({delete_block, ReplyPid, Bucket, Key, UUID, BlockNumber}, State=#state{riakc_pid=RiakcPid}) ->
    dt_entry(<<"delete_block">>, [BlockNumber], [Bucket, Key]),
    {FullBucket, FullKey} = full_bkey(Bucket, Key, UUID, BlockNumber),
    StartTime = os:timestamp(),

    %% do a get first to get the vclock (only do a head request though)
    GetOptions = [{r, 1}, {notfound_ok, false}, {basic_quorum, false}, head],
    _ = case riakc_pb_socket:get(RiakcPid, FullBucket, FullKey, GetOptions) of
            {ok, RiakObject} ->
                ok = delete_block(RiakcPid, ReplyPid, RiakObject, {UUID, BlockNumber});
        {error, notfound} ->
            %% If the block isn't found, assume it's been
            %% previously deleted by another delete FSM, and
            %% move on to the next block.
            riak_cs_delete_fsm:block_deleted(ReplyPid, {ok, {UUID, BlockNumber}})
    end,
    ok = riak_cs_stats:update_with_start(block_delete, StartTime),
    dt_return(<<"delete_block">>, [BlockNumber], [Bucket, Key]),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

delete_block(RiakcPid, ReplyPid, RiakObject, BlockId) ->
    Result = constrained_delete(RiakcPid, RiakObject, BlockId),
    _ = secondary_delete_check(Result, RiakcPid, RiakObject),
    riak_cs_delete_fsm:block_deleted(ReplyPid, Result),
    ok.

constrained_delete(RiakcPid, RiakObject, BlockId) ->
    DeleteOptions = [{r, all}, {pr, all}, {w, all}, {pw, all}],
    format_delete_result(
      riakc_pb_socket:delete_obj(RiakcPid, RiakObject, DeleteOptions),
      BlockId).

secondary_delete_check({error, {unsatisfied_constraint, _, _}}, RiakcPid, RiakObject) ->
    riakc_pb_socket:delete_obj(RiakcPid, RiakObject);
secondary_delete_check(_, _, _) ->
    ok.

format_delete_result(ok, BlockId) ->
    {ok, BlockId};
format_delete_result({error, Reason}, BlockId) when is_binary(Reason) ->
    %% Riak client sends back oddly formatted errors
    format_delete_result({error, binary_to_list(Reason)}, BlockId);
format_delete_result({error, "{r_val_unsatisfied," ++ _}, BlockId) ->
    {error, {unsatisfied_constraint, r, BlockId}};
format_delete_result({error, "{w_val_unsatisfied," ++ _}, BlockId) ->
    {error, {unsatisfied_constraint, w, BlockId}};
format_delete_result({error, "{pr_val_unsatisfied," ++ _}, BlockId) ->
    {error, {unsatisfied_constraint, pr, BlockId}};
format_delete_result({error, "{pw_val_unsatisfied," ++ _}, BlockId) ->
    {error, {unsatisfied_constraint, pw, BlockId}};
format_delete_result(Result, _) ->
    Result.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, #state{riakc_pid=RiakcPid,
                          close_riak_connection=CloseConn}) ->
    case CloseConn of
        true ->
            riak_cs_utils:close_riak_connection(RiakcPid),
            ok;
        false ->
            ok
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec full_bkey(binary(), binary(), binary(), pos_integer()) -> {binary(), binary()}.
%% @private
full_bkey(Bucket, Key, UUID, BlockId) ->
    PrefixedBucket = riak_cs_utils:to_bucket_name(blocks, Bucket),
    FullKey = riak_cs_lfs_utils:block_name(Key, UUID, BlockId),
    {PrefixedBucket, FullKey}.

fold_object_csum_fun({MD, V}, {PrevV, NeedsRepair, BCSum}) ->
    case find_rcs_bcsum(MD) of
        undefined when NeedsRepair == false ->
            {V, NeedsRepair, BCSum};
        undefined when NeedsRepair == true ->
            {PrevV, true, BCSum};
        CorrectBCSum when is_binary(CorrectBCSum) ->
            case crypto:md5(V) of
                X when X =:= CorrectBCSum ->
                    {V, NeedsRepair, CorrectBCSum};
                _Bad ->
                    {PrevV, true, BCSum}
            end
    end.

find_rcs_bcsum(MD) ->
    proplists:get_value(<<?USERMETA_BCSUM>>, find_md_usermeta(MD)).

find_md_usermeta(MD) ->
    dict:fetch(?MD_USERMETA, MD).

resolve_block_object(RObj, RiakcPid) ->
    Cs = riakc_obj:get_contents(RObj),
    Init = {not_done_unused, false, unknown_csum},
    {Value, NeedRepair, BCSum} = lists:foldl(fun fold_object_csum_fun/2, Init, Cs),
    if NeedRepair andalso is_binary(Value) ->
            RBucket = riakc_obj:bucket(RObj),
            RKey = riakc_obj:key(RObj),
            S3Info = find_md_usermeta(hd(riakc_obj:get_metadatas(RObj))),
            lager:info("Repairing riak ~p ~p for ~p\n",[RBucket, RKey, S3Info]),
            Bucket = proplists:get_value(<<?USERMETA_BUCKET>>, S3Info),
            Key = proplists:get_value(<<?USERMETA_KEY>>, S3Info),
            VClock = riakc_obj:vclock(RObj),
            MD = make_md_usermeta([{?USERMETA_BUCKET, Bucket},
                                   {?USERMETA_KEY, Key},
                                   {?USERMETA_BCSUM, BCSum}]),
            FailFun = fun(Error) ->
                          lager:error("Put S3 ~p ~p Riak ~p ~p failed: ~p\n",
                                      [Bucket, Key, RBucket, RKey, Error])
                      end,
            do_put_block(RBucket, RKey, VClock, Value, MD, RiakcPid, FailFun);
       true ->
            ok
    end,
    if is_binary(Value) ->
            {ok, Value};
       true ->
            {error, notfound}
    end.

make_md_usermeta(Props) ->
    dict:from_list([{?MD_USERMETA, Props}]).

do_put_block(FullBucket, FullKey, VClock, Value, MD, RiakcPid, FailFun) ->
    RiakObject0 = riakc_obj:new(FullBucket, FullKey, Value),
    RiakObject = riakc_obj:set_vclock(
                   riakc_obj:update_metadata(RiakObject0, MD), VClock),
    StartTime = os:timestamp(),
    case riakc_pb_socket:put(RiakcPid, RiakObject) of
        ok ->
            ok = riak_cs_stats:update_with_start(block_put, StartTime),
            ok;
        Else ->
            FailFun(Else),
            Else
    end.

dt_entry(Func, Ints, Strings) ->
    riak_cs_dtrace:dtrace(?DT_BLOCK_OP, 1, Ints, ?MODULE, Func, Strings).

dt_return(Func, Ints, Strings) ->
    riak_cs_dtrace:dtrace(?DT_BLOCK_OP, 2, Ints, ?MODULE, Func, Strings).
