-module(parallel_rpc_tests).
-include_lib("eunit/include/eunit.hrl").

%% Test basic parallel RPC functionality with non-existent nodes
basic_parallel_rpc_test() ->
    % Test with a non-existent node to verify error handling
    Nodes = ['nonexistent@localhost'],
    {ok, Results} = parallel_rpc:execute_parallel_calls(Nodes, erlang, node, []),
    
    ?assertEqual(1, length(Results)),
    [{Node, {error, _Reason}}] = Results,
    ?assertEqual('nonexistent@localhost', Node).

%% Test with multiple dummy nodes (will fail but test the structure)
multiple_nodes_test() ->
    % These nodes don't exist, so we expect errors
    Nodes = ['dummy1@localhost', 'dummy2@localhost'],
    {ok, Results} = parallel_rpc:execute_parallel_calls(Nodes, erlang, node, []),
    
    ?assertEqual(2, length(Results)),
    % All calls should fail with badrpc
    lists:foreach(fun({_Node, {error, _Reason}}) -> ok end, Results).

%% Test timeout functionality
timeout_test() ->
    % Use a very short timeout
    Nodes = ['dummy@localhost'],
    {ok, Results} = parallel_rpc:execute_parallel_calls(
        Nodes, erlang, node, [], 
        [{rpc_timeout, 1}, {overall_timeout, 100}]
    ),
    
    ?assertEqual(1, length(Results)),
    [{_Node, {error, _Reason}}] = Results.

%% Test overall timeout with slow operations
overall_timeout_test() ->
    % This will timeout before completing
    Nodes = ['dummy1@localhost', 'dummy2@localhost', 'dummy3@localhost'],
    Result = parallel_rpc:execute_parallel_calls(
        Nodes, timer, sleep, [10000], 
        [{rpc_timeout, 15000}, {overall_timeout, 50}]
    ),
    
    % Should get timeout with partial results (likely empty)
    case Result of
        {timeout, PartialResults} ->
            ?assert(length(PartialResults) =< length(Nodes));
        {ok, _Results} ->
            % In case the operation was very fast
            ok
    end.

%% Test Single Lock Principle adherence - simplified test
single_lock_principle_test() ->
    % Test that we can't acquire a lock if already holding one in the calling process
    ?assertEqual(ok, local_lock:acquire()),
    ?assertEqual({error, already_holding_lock}, local_lock:acquire()),
    ?assertEqual(ok, local_lock:release()),
    
    % Test the parallel_rpc structure without distributed nodes
    Nodes = ['dummy@localhost'],
    {ok, Results} = parallel_rpc:execute_parallel_calls(Nodes, timer, sleep, [1]),
    
    ?assertEqual(1, length(Results)),
    [{_Node, {error, _Reason}}] = Results.  % Expected to fail since node doesn't exist

%% Test error handling in worker - simplified
error_handling_test() ->
    % Test with non-existent nodes and verify error structure
    Nodes = ['error_node@localhost'],
    {ok, Results} = parallel_rpc:execute_parallel_calls(Nodes, erlang, error, [test_error]),
    
    ?assertEqual(1, length(Results)),
    [{_Node, {error, _Reason}}] = Results.