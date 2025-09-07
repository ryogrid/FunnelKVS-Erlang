%%%-------------------------------------------------------------------
%%% @doc Large scale tests for FunnelKVS-Erlang
%%% This module contains comprehensive tests for multi-node scenarios
%%% including node failures and data persistence verification.
%%% @end
%%%-------------------------------------------------------------------
-module(chord_large_scale_tests).

-include("../include/chord.hrl").
-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Test Descriptions
%%%===================================================================

large_scale_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [
      {"10-node cluster with failures", {timeout, 300, fun test_ten_node_cluster_with_failures/0}}
     ]
    }.

%%%===================================================================
%%% Setup and Teardown
%%%===================================================================

setup() ->
    % Ensure clean state
    ok.

teardown(_) ->
    % Clean up any remaining processes
    ok.

%%%===================================================================
%%% Tests
%%%===================================================================

%% Test comprehensive 10-node scenario with data persistence through failures
test_ten_node_cluster_with_failures() ->
    io:format("~n=== Starting 10-node cluster test ===~n"),
    
    %% Phase 1: Start 10 nodes and wait for stabilization
    io:format("Phase 1: Starting 10 nodes...~n"),
    BasePort = 18000,
    Nodes = start_nodes(10, BasePort),
    
    io:format("Waiting for cluster stabilization (25 seconds)...~n"),
    timer:sleep(25000),  % Wait for full stabilization with larger ring
    
    %% Phase 2: Put values on nodes 1, 3, 6 and verify from other nodes
    io:format("Phase 2: Storing and verifying data...~n"),
    Node1 = lists:nth(2, Nodes),  % Index 2 = Node ID 1
    Node3 = lists:nth(4, Nodes),  % Index 4 = Node ID 3  
    Node6 = lists:nth(7, Nodes),  % Index 7 = Node ID 6
    
    TestData = [
        {Node1, <<"key_on_node1">>, <<"value_from_node1">>},
        {Node3, <<"key_on_node3">>, <<"value_from_node3">>},
        {Node6, <<"key_on_node6">>, <<"value_from_node6">>}
    ],
    
    % Store data on specific nodes using eventual consistency for faster startup
    lists:foreach(fun({TargetNode, Key, Value}) ->
        io:format("Storing ~p=~p on node ~p~n", [Key, Value, get_node_id(TargetNode)]),
        ?assertEqual(ok, chord:put(TargetNode, Key, Value, eventual))
    end, TestData),
    
    % Wait for replication and network stabilization
    timer:sleep(10000),
    
    % Verify data can be read from all nodes using eventual consistency
    AllKeys = [{Key, Value} || {_Node, Key, Value} <- TestData],
    lists:foreach(fun(Node) ->
        lists:foreach(fun({Key, ExpectedValue}) ->
            case chord:get(Node, Key, eventual) of
                {ok, ExpectedValue} ->
                    io:format("✓ Key ~p correctly retrieved from node ~p~n", 
                             [Key, get_node_id(Node)]);
                {error, not_found} ->
                    io:format("⚠ Key ~p not yet replicated to node ~p (acceptable during startup)~n", 
                             [Key, get_node_id(Node)]);
                Other ->
                    io:format("✗ Unexpected result for key ~p from node ~p: ~p~n", 
                             [Key, get_node_id(Node), Other])
            end
        end, AllKeys)
    end, Nodes),
    
    %% Phase 3: Shutdown only the nodes that stored the data (nodes 1,3,6)
    io:format("Phase 3: Sequential node shutdown of data-storing nodes...~n"),
    % Shutdown nodes at indices 2,4,7 = Node IDs 1,3,6 (the nodes that stored data)
    % This tests if replicas were properly distributed to other nodes
    NodestoShutdown = [2, 4, 7],  % List indices for nodes 1,3,6
    RemainingNodes = shutdown_nodes_sequentially(Nodes, NodestoShutdown),
    
    io:format("Waiting for network stabilization after failures (10 seconds)...~n"),
    timer:sleep(10000),
    
    %% Phase 4: Verify ALL data is accessible from ALL remaining nodes
    io:format("Phase 4: Verifying all data accessible from all remaining nodes...~n"),
    
    % Check that every remaining node can retrieve every key
    AllRetrievable = lists:all(fun(Node) ->
        NodeId = get_node_id(Node),
        io:format("Testing data retrieval from remaining node ~p...~n", [NodeId]),
        lists:all(fun({Key, ExpectedValue}) ->
            case chord:get(Node, Key, eventual) of
                {ok, ExpectedValue} ->
                    io:format("✓ Key ~p successfully retrieved from node ~p~n", [Key, NodeId]),
                    true;
                {error, not_found} ->
                    io:format("✗ Key ~p not found on node ~p - REPLICATION FAILED~n", [Key, NodeId]),
                    false;
                Other ->
                    io:format("✗ Unexpected result for key ~p from node ~p: ~p~n", [Key, NodeId, Other]),
                    false
            end
        end, AllKeys)
    end, RemainingNodes),
    
    % Calculate and display results
    TotalKeys = length(AllKeys),
    TotalNodes = length(RemainingNodes),
    if AllRetrievable ->
        io:format("~n=== TEST PASSED: All ~p keys accessible from all ~p remaining nodes ===~n", 
                 [TotalKeys, TotalNodes]),
        io:format("=== Replication system working correctly after original nodes shutdown ===~n~n");
       true ->
        io:format("~n=== TEST FAILED: Not all keys accessible from all remaining nodes ===~n"),
        io:format("=== Replication system failed to maintain data availability ===~n~n")
    end,
    
    % This test requires ALL keys to be retrievable from ALL remaining nodes
    ?assert(AllRetrievable),
    
    %% Clean up remaining nodes
    io:format("Cleaning up remaining nodes...~n"),
    lists:foreach(fun(Node) ->
        chord:stop_node(Node)
    end, RemainingNodes),
    
    io:format("=== 10-node cluster test completed successfully ===~n"),
    ok.

%%%===================================================================
%%% Helper Functions
%%%===================================================================

%% Start N nodes with sequential IDs
start_nodes(N, BasePort) ->
    start_nodes(N, BasePort, 0, []).

start_nodes(0, _BasePort, _IdCounter, Acc) ->
    lists:reverse(Acc);
start_nodes(N, BasePort, IdCounter, Acc) ->
    Port = BasePort + IdCounter,
    io:format("Starting node ~p on port ~p...~n", [IdCounter, Port]),
    {ok, Node} = chord:start_node(IdCounter, Port),
    
    case IdCounter of
        0 ->
            % First node creates the ring
            ok = chord:create_ring(Node);
        _ ->
            % Other nodes join the ring with retry logic
            case chord:join_ring(Node, "localhost", BasePort) of
                ok -> 
                    timer:sleep(2000);  % Longer pause between joins for stability
                {error, Reason} ->
                    io:format("Failed to join ring for node ~p: ~p~n", [IdCounter, Reason]),
                    % Retry once
                    timer:sleep(1000),
                    ok = chord:join_ring(Node, "localhost", BasePort),
                    timer:sleep(2000)
            end
    end,
    
    start_nodes(N-1, BasePort, IdCounter+1, [Node | Acc]).

%% Shutdown specified nodes sequentially
shutdown_nodes_sequentially(AllNodes, IndicesToShutdown) ->
    % Shutdown nodes one by one
    lists:foreach(fun(Index) ->
        Node = lists:nth(Index, AllNodes),
        NodeId = get_node_id(Node),
        io:format("Shutting down node ~p (index ~p)...~n", [NodeId, Index]),
        chord:stop_node(Node),
        timer:sleep(6000)  % 6-second interval between shutdowns
    end, IndicesToShutdown),
    
    % Return remaining nodes (those not shut down)
    AllIndices = lists:seq(1, length(AllNodes)),
    RemainingIndices = AllIndices -- IndicesToShutdown,
    [lists:nth(I, AllNodes) || I <- RemainingIndices].

%% Get node ID for logging purposes
get_node_id(Node) ->
    try
        chord:get_id(Node)
    catch
        _:_ -> unknown
    end.