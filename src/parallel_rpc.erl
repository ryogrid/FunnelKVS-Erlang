%% @doc Parallel RPC execution using spawn/3, honoring the Single Lock Principle.
%%      - Each worker acquires at most one local lock-equivalent during its RPC.
%%      - No lock ordering, no process monitoring.
%%      - Supports per-RPC timeout and overall timeout; cancels remaining workers on overall timeout.

-module(parallel_rpc).
-export([
    execute_parallel_calls/4,
    execute_parallel_calls/5,
    worker/7  % exported for spawn/3
]).

-define(DEFAULT_RPC_TIMEOUT, 5000).        %% per rpc:call timeout (ms)
-define(DEFAULT_OVERALL_TIMEOUT, 5000).    %% overall collection timeout (ms)

%% API
-spec execute_parallel_calls([node()], module(), atom(), [term()]) ->
          {ok, [{node(), {ok, term()} | {error, term()}}]}
        | {timeout, [{node(), {ok, term()} | {error, term()}}]}.
execute_parallel_calls(Nodes, Module, Function, Args) ->
    execute_parallel_calls(Nodes, Module, Function, Args, []).

-spec execute_parallel_calls([node()], module(), atom(), [term()], proplists:proplist()) ->
          {ok, [{node(), {ok, term()} | {error, term()}}]}
        | {timeout, [{node(), {ok, term()} | {error, term()}}]}.
execute_parallel_calls(Nodes, Module, Function, Args, Opts) ->
    RpcTimeout     = proplists:get_value(rpc_timeout, Opts, ?DEFAULT_RPC_TIMEOUT),
    OverallTimeout = proplists:get_value(overall_timeout, Opts, ?DEFAULT_OVERALL_TIMEOUT),
    Parent         = self(),
    ReqId          = make_ref(),

    %% Spawn one worker per node (no link, no monitor)
    Workers = [spawn(?MODULE, worker, [Parent, ReqId, Node, Module, Function, Args, RpcTimeout])
               || Node <- Nodes],

    collect_results(Workers, ReqId, length(Nodes), OverallTimeout).

%% Internal worker: holds a single local lock for the duration of rpc:call/5.
worker(Parent, ReqId, Node, Module, Function, Args, RpcTimeout) ->
    case local_lock:acquire(Node) of
        ok ->
            Result = do_rpc(Node, Module, Function, Args, RpcTimeout),
            _ = local_lock:release(Node),
            Parent ! {ReqId, self(), Node, Result};
        {error, already_holding_lock} ->
            %% Should not happen per-worker, but be explicit.
            Parent ! {ReqId, self(), Node, {error, already_holding_lock}}
    end.

do_rpc(Node, Module, Function, Args, RpcTimeout) ->
    try
        {ok, rpc:call(Node, Module, Function, Args, RpcTimeout)}
    catch
        Class:Reason:Stack ->
            {error, {rpc_exception, Class, Reason, Stack}}
    end.

%% Collect results with an overall timeout. If timeout fires, cancel remaining workers.
collect_results(Workers, ReqId, Expected, OverallTimeout) ->
    Deadline = erlang:monotonic_time(millisecond) + OverallTimeout,
    collect_loop(Workers, ReqId, Expected, [], Deadline).

collect_loop(_Workers, _ReqId, 0, Acc, _Deadline) ->
    {ok, lists:reverse(Acc)};
collect_loop(Workers, ReqId, Expected, Acc, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    Rem = Deadline - Now,
    if
        Rem =< 0 ->
            %% Overall timeout: best-effort cancel remaining workers
            [exit(Pid, kill) || Pid <- Workers],
            {timeout, lists:reverse(Acc)};
        true ->
            receive
                {ReqId, Pid, Node, Result} ->
                    RestWorkers = lists:delete(Pid, Workers),
                    collect_loop(RestWorkers, ReqId, Expected - 1, [{Node, Result} | Acc], Deadline)
            after Rem ->
                %% Timer raced with receive mailbox empty: cancel
                [exit(Pid, kill) || Pid <- Workers],
                {timeout, lists:reverse(Acc)}
            end
    end.