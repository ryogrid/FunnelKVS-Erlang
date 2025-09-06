-module(chord_multinode_tests).
-include_lib("eunit/include/eunit.hrl").
-include("../include/chord.hrl").

-define(TIMEOUT, 5000).

%%% Tests for multi-node Chord operations

setup() ->
    ok.

teardown(_) ->
    ok.

chord_multinode_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [
      {"Node join protocol", fun test_node_join/0},
      {"Key migration on join", fun test_key_migration_on_join/0},
      {"Multi-node stabilization", fun test_multinode_stabilization/0},
      {"Graceful node departure", fun test_graceful_departure/0},
      {"Failure detection", fun test_failure_detection/0},
      {"Ring consistency after joins", fun test_ring_consistency_after_joins/0},
      {"Key distribution across nodes", fun test_key_distribution/0},
      {"Concurrent joins", fun test_concurrent_joins/0},
      {"Node departure with key transfer", fun test_departure_with_key_transfer/0},
      {"Failure recovery", fun test_failure_recovery/0}
     ]}.

%% Test node join protocol
test_node_join() ->
    %% Start first node
    {ok, Node1} = chord:start_node(1, 8001),
    
    %% Create the ring
    ok = chord:create_ring(Node1),
    
    %% Start second node
    {ok, Node2} = chord:start_node(2, 8002),
    
    %% Join the ring through Node1
    ok = chord:join_ring(Node2, "localhost", 8001),
    
    %% Wait for stabilization
    timer:sleep(1000),
    
    %% Verify both nodes know about each other
    {ok, Successor1} = chord:get_successor(Node1),
    {ok, Predecessor1} = chord:get_predecessor(Node1),
    {ok, Successor2} = chord:get_successor(Node2),
    {ok, Predecessor2} = chord:get_predecessor(Node2),
    
    %% In a two-node ring, each node should point to the other
    ?assertEqual(2, Successor1#node_info.id),
    ?assertEqual(2, Predecessor1#node_info.id),
    ?assertEqual(1, Successor2#node_info.id),
    ?assertEqual(1, Predecessor2#node_info.id),
    
    %% Stop nodes
    chord:stop_node(Node1),
    chord:stop_node(Node2).

%% Test key migration when a new node joins
test_key_migration_on_join() ->
    %% Start first node and create ring
    {ok, Node1} = chord:start_node(1, 8001),
    ok = chord:create_ring(Node1),
    
    %% Insert some keys into Node1
    Keys = [
        {<<"key1">>, <<"value1">>},
        {<<"key2">>, <<"value2">>},
        {<<"key3">>, <<"value3">>},
        {<<"key4">>, <<"value4">>},
        {<<"key5">>, <<"value5">>}
    ],
    
    lists:foreach(fun({K, V}) ->
        ok = chord:put(Node1, K, V)
    end, Keys),
    
    %% Start second node and join
    {ok, Node2} = chord:start_node(2, 8002),
    ok = chord:join_ring(Node2, "localhost", 8001),
    
    %% Wait for stabilization and key migration
    timer:sleep(2000),
    
    %% Verify keys are accessible from both nodes
    lists:foreach(fun({K, V}) ->
        {ok, V1} = chord:get(Node1, K),
        {ok, V2} = chord:get(Node2, K),
        ?assertEqual(V, V1),
        ?assertEqual(V, V2)
    end, Keys),
    
    %% Verify keys are stored on the correct nodes
    lists:foreach(fun({K, _V}) ->
        KeyHash = chord:hash(K),
        {ok, ResponsibleNode} = chord:find_successor(Node1, KeyHash),
        
        %% Key should be stored on the responsible node
        LocalKeys = chord:get_local_keys(ResponsibleNode),
        ?assert(lists:member(K, LocalKeys))
    end, Keys),
    
    chord:stop_node(Node1),
    chord:stop_node(Node2).

%% Test multi-node ring stabilization
test_multinode_stabilization() ->
    %% Start multiple nodes
    Nodes = lists:map(fun(I) ->
        Port = 8000 + I,
        {ok, Node} = chord:start_node(I, Port),
        Node
    end, lists:seq(1, 4)),
    
    [Node1, Node2, Node3, Node4] = Nodes,
    
    %% Create ring with first node
    ok = chord:create_ring(Node1),
    
    %% Join other nodes sequentially
    ok = chord:join_ring(Node2, "localhost", 8001),
    timer:sleep(500),
    ok = chord:join_ring(Node3, "localhost", 8001),
    timer:sleep(500),
    ok = chord:join_ring(Node4, "localhost", 8001),
    
    %% Wait for stabilization
    timer:sleep(3000),
    
    %% Verify ring consistency
    lists:foreach(fun(Node) ->
        {ok, Successor} = chord:get_successor(Node),
        {ok, Predecessor} = chord:get_predecessor(Node),
        
        %% Successor's predecessor should be this node
        {ok, SuccPred} = chord:get_predecessor(Successor),
        ?assertEqual(Node, SuccPred),
        
        %% Predecessor's successor should be this node
        {ok, PredSucc} = chord:get_successor(Predecessor),
        ?assertEqual(Node, PredSucc)
    end, Nodes),
    
    %% Stop all nodes
    lists:foreach(fun chord:stop_node/1, Nodes).

%% Test graceful node departure
test_graceful_departure() ->
    %% Start three nodes
    {ok, Node1} = chord:start_node(1, 8001),
    {ok, Node2} = chord:start_node(2, 8002),
    {ok, Node3} = chord:start_node(3, 8003),
    
    %% Create ring
    ok = chord:create_ring(Node1),
    ok = chord:join_ring(Node2, "localhost", 8001),
    ok = chord:join_ring(Node3, "localhost", 8001),
    
    timer:sleep(2000),
    
    %% Insert some keys
    Keys = [
        {<<"keyA">>, <<"valueA">>},
        {<<"keyB">>, <<"valueB">>},
        {<<"keyC">>, <<"valueC">>}
    ],
    
    lists:foreach(fun({K, V}) ->
        ok = chord:put(Node1, K, V)
    end, Keys),
    
    timer:sleep(1000),
    
    %% Gracefully leave with Node2
    ok = chord:leave_ring(Node2),
    
    %% Wait for stabilization
    timer:sleep(2000),
    
    %% Verify ring is still consistent
    {ok, Succ1} = chord:get_successor(Node1),
    {ok, Pred1} = chord:get_predecessor(Node1),
    {ok, Succ3} = chord:get_successor(Node3),
    {ok, Pred3} = chord:get_predecessor(Node3),
    
    ?assertEqual(3, Succ1#node_info.id),
    ?assertEqual(3, Pred1#node_info.id),
    ?assertEqual(1, Succ3#node_info.id),
    ?assertEqual(1, Pred3#node_info.id),
    
    %% Verify all keys are still accessible
    lists:foreach(fun({K, V}) ->
        {ok, Value} = chord:get(Node1, K),
        ?assertEqual(V, Value)
    end, Keys),
    
    chord:stop_node(Node1),
    chord:stop_node(Node3).

%% Test failure detection
test_failure_detection() ->
    %% Start three nodes
    {ok, Node1} = chord:start_node(1, 8001),
    {ok, Node2} = chord:start_node(2, 8002),
    {ok, Node3} = chord:start_node(3, 8003),
    
    %% Create ring
    ok = chord:create_ring(Node1),
    ok = chord:join_ring(Node2, "localhost", 8001),
    ok = chord:join_ring(Node3, "localhost", 8001),
    
    timer:sleep(2000),
    
    %% Insert keys
    ok = chord:put(Node1, <<"test_key">>, <<"test_value">>),
    
    %% Abruptly stop Node2 (simulate failure)
    chord:stop_node(Node2),
    
    %% Wait for failure detection
    timer:sleep(3000),
    
    %% Verify ring has healed
    {ok, Succ1} = chord:get_successor(Node1),
    {ok, Pred1} = chord:get_predecessor(Node1),
    {ok, Succ3} = chord:get_successor(Node3),
    {ok, Pred3} = chord:get_predecessor(Node3),
    
    %% Node1 and Node3 should now point to each other
    ?assertEqual(3, Succ1#node_info.id),
    ?assertEqual(3, Pred1#node_info.id),
    ?assertEqual(1, Succ3#node_info.id),
    ?assertEqual(1, Pred3#node_info.id),
    
    %% Key should still be accessible
    {ok, Value} = chord:get(Node1, <<"test_key">>),
    ?assertEqual(<<"test_value">>, Value),
    
    chord:stop_node(Node1),
    chord:stop_node(Node3).

%% Test ring consistency after multiple joins
test_ring_consistency_after_joins() ->
    %% Start and join 5 nodes
    Nodes = lists:map(fun(I) ->
        Port = 8000 + I,
        {ok, Node} = chord:start_node(I, Port),
        if 
            I == 1 -> chord:create_ring(Node);
            true -> chord:join_ring(Node, "localhost", 8001)
        end,
        timer:sleep(500),
        Node
    end, lists:seq(1, 5)),
    
    %% Wait for full stabilization
    timer:sleep(3000),
    
    %% Verify ring forms a cycle
    verify_ring_cycle(Nodes),
    
    %% Stop all nodes
    lists:foreach(fun chord:stop_node/1, Nodes).

%% Test key distribution across nodes
test_key_distribution() ->
    %% Start 3 nodes
    Nodes = lists:map(fun(I) ->
        Port = 8000 + I,
        {ok, Node} = chord:start_node(I, Port),
        if 
            I == 1 -> chord:create_ring(Node);
            true -> chord:join_ring(Node, "localhost", 8001)
        end,
        timer:sleep(500),
        Node
    end, lists:seq(1, 3)),
    
    timer:sleep(2000),
    
    %% Insert many keys
    Keys = lists:map(fun(I) ->
        K = <<"key", (integer_to_binary(I))/binary>>,
        V = <<"value", (integer_to_binary(I))/binary>>,
        ok = chord:put(hd(Nodes), K, V),
        {K, V}
    end, lists:seq(1, 30)),
    
    timer:sleep(1000),
    
    %% Check distribution
    Distribution = lists:map(fun(Node) ->
        LocalKeys = chord:get_local_keys(Node),
        {Node, length(LocalKeys)}
    end, Nodes),
    
    %% Each node should have some keys
    lists:foreach(fun({_Node, Count}) ->
        ?assert(Count > 0)
    end, Distribution),
    
    %% Verify all keys are accessible
    lists:foreach(fun({K, V}) ->
        {ok, Value} = chord:get(hd(Nodes), K),
        ?assertEqual(V, Value)
    end, Keys),
    
    lists:foreach(fun chord:stop_node/1, Nodes).

%% Test concurrent node joins
test_concurrent_joins() ->
    %% Start first node
    {ok, Node1} = chord:start_node(1, 8001),
    ok = chord:create_ring(Node1),
    
    timer:sleep(500),
    
    %% Start multiple nodes concurrently
    Pids = lists:map(fun(I) ->
        spawn(fun() ->
            Port = 8000 + I,
            {ok, Node} = chord:start_node(I, Port),
            ok = chord:join_ring(Node, "localhost", 8001),
            receive
                stop -> chord:stop_node(Node)
            end
        end)
    end, lists:seq(2, 4)),
    
    %% Wait for joins to complete
    timer:sleep(5000),
    
    %% Verify ring is consistent
    {ok, AllNodes} = chord:get_ring_nodes(Node1),
    ?assertEqual(4, length(AllNodes)),
    
    %% Stop all spawned nodes
    lists:foreach(fun(Pid) -> Pid ! stop end, Pids),
    timer:sleep(500),
    
    chord:stop_node(Node1).

%% Test node departure with key transfer
test_departure_with_key_transfer() ->
    %% Start three nodes
    {ok, Node1} = chord:start_node(1, 8001),
    {ok, Node2} = chord:start_node(2, 8002),
    {ok, Node3} = chord:start_node(3, 8003),
    
    ok = chord:create_ring(Node1),
    ok = chord:join_ring(Node2, "localhost", 8001),
    ok = chord:join_ring(Node3, "localhost", 8001),
    
    timer:sleep(2000),
    
    %% Insert keys that would be on Node2
    TestKeys = lists:map(fun(I) ->
        K = <<"depart_key", (integer_to_binary(I))/binary>>,
        V = <<"depart_value", (integer_to_binary(I))/binary>>,
        ok = chord:put(Node2, K, V),
        {K, V}
    end, lists:seq(1, 10)),
    
    timer:sleep(1000),
    
    %% Node2 leaves gracefully
    ok = chord:leave_ring(Node2),
    
    timer:sleep(2000),
    
    %% All keys should still be accessible through remaining nodes
    lists:foreach(fun({K, V}) ->
        {ok, Value} = chord:get(Node1, K),
        ?assertEqual(V, Value)
    end, TestKeys),
    
    chord:stop_node(Node1),
    chord:stop_node(Node3).

%% Test failure recovery
test_failure_recovery() ->
    %% Start four nodes
    Nodes = lists:map(fun(I) ->
        Port = 8000 + I,
        {ok, Node} = chord:start_node(I, Port),
        if 
            I == 1 -> chord:create_ring(Node);
            true -> chord:join_ring(Node, "localhost", 8001)
        end,
        timer:sleep(500),
        Node
    end, lists:seq(1, 4)),
    
    [Node1, Node2, Node3, Node4] = Nodes,
    
    timer:sleep(2000),
    
    %% Insert test data
    ok = chord:put(Node1, <<"recovery_key">>, <<"recovery_value">>),
    
    %% Simulate multiple failures
    chord:stop_node(Node2),
    chord:stop_node(Node3),
    
    %% Wait for recovery
    timer:sleep(4000),
    
    %% Verify remaining nodes form consistent ring
    {ok, Succ1} = chord:get_successor(Node1),
    {ok, Pred1} = chord:get_predecessor(Node1),
    {ok, Succ4} = chord:get_successor(Node4),
    {ok, Pred4} = chord:get_predecessor(Node4),
    
    ?assertEqual(4, Succ1#node_info.id),
    ?assertEqual(4, Pred1#node_info.id),
    ?assertEqual(1, Succ4#node_info.id),
    ?assertEqual(1, Pred4#node_info.id),
    
    %% Data should still be accessible
    {ok, Value} = chord:get(Node1, <<"recovery_key">>),
    ?assertEqual(<<"recovery_value">>, Value),
    
    chord:stop_node(Node1),
    chord:stop_node(Node4).

%% Helper function to verify ring forms a proper cycle
verify_ring_cycle(Nodes) ->
    %% Start from first node and follow successors
    StartNode = hd(Nodes),
    Visited = follow_successors(StartNode, StartNode, []),
    
    %% Should visit all nodes exactly once
    ?assertEqual(length(Nodes), length(Visited)),
    ?assertEqual(lists:sort(Nodes), lists:sort(Visited)).

follow_successors(CurrentNode, StartNode, Visited) ->
    case lists:member(CurrentNode, Visited) of
        true ->
            %% We've completed the cycle
            ?assertEqual(StartNode, CurrentNode),
            Visited;
        false ->
            {ok, Successor} = chord:get_successor(CurrentNode),
            follow_successors(Successor, StartNode, [CurrentNode | Visited])
    end.