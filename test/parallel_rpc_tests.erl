%% @doc Tests for parallel_rpc module  
-module(parallel_rpc_tests).
-include_lib("eunit/include/eunit.hrl").

%% Export helper functions for RPC calls
-export([test_function/1, slow_function/2]).

%% Helper function for testing - just returns the input
test_function(Arg) ->
    Arg.

%% Helper function that takes some time
slow_function(Time, Value) ->
    timer:sleep(Time),
    Value.

%% Test basic parallel RPC functionality
basic_parallel_rpc_test() ->
    %% Test with node() (current node)
    Nodes = [node()],
    Args = [hello_world],
    
    Result = parallel_rpc:execute_parallel_calls(Nodes, ?MODULE, test_function, Args),
    
    ?assertMatch({ok, [{_, {ok, hello_world}}]}, Result),
    {ok, [{Node, {ok, Value}}]} = Result,
    ?assertEqual(node(), Node),
    ?assertEqual(hello_world, Value).

%% Test with multiple nodes (all current node for simplicity)
multiple_nodes_test() ->
    Nodes = [node(), node(), node()],
    Args = [test_value],
    
    Result = parallel_rpc:execute_parallel_calls(Nodes, ?MODULE, test_function, Args),
    
    ?assertMatch({ok, [_, _, _]}, Result),
    {ok, Results} = Result,
    
    %% All should return the same value
    Expected = {node(), {ok, test_value}},
    ?assertEqual([Expected, Expected, Expected], Results).

%% Test timeout functionality  
timeout_test() ->
    Nodes = [node()],
    Args = [2000, test_value],  %% Sleep 2 seconds
    Opts = [{rpc_timeout, 5000}, {overall_timeout, 1000}],  %% Overall timeout 1 second
    
    Result = parallel_rpc:execute_parallel_calls(Nodes, ?MODULE, slow_function, Args, Opts),
    
    %% Should timeout since overall timeout (1s) < sleep time (2s)
    ?assertMatch({timeout, []}, Result).

%% Test successful call with timeouts
successful_with_timeout_test() ->
    Nodes = [node()],
    Args = [100, success_value],  %% Sleep 100ms
    Opts = [{rpc_timeout, 5000}, {overall_timeout, 2000}],  %% Plenty of time
    
    Result = parallel_rpc:execute_parallel_calls(Nodes, ?MODULE, slow_function, Args, Opts),
    
    ?assertMatch({ok, [{_, {ok, success_value}}]}, Result).

%% Test error handling
error_handling_test() ->
    Nodes = [node()],
    Args = [non_existent_arg],
    
    %% Call a non-existent function 
    Result = parallel_rpc:execute_parallel_calls(Nodes, ?MODULE, non_existent_function, Args),
    
    ?assertMatch({ok, [{_, {ok, {badrpc, _}}}]}, Result),
    {ok, [{Node, {ok, {badrpc, Error}}}]} = Result,
    ?assertEqual(node(), Node),
    %% Should be an EXIT with undef error
    ?assertMatch({'EXIT', {undef, _}}, Error).

%% Test empty node list
empty_nodes_test() ->
    Result = parallel_rpc:execute_parallel_calls([], ?MODULE, test_function, [test]),
    ?assertEqual({ok, []}, Result).