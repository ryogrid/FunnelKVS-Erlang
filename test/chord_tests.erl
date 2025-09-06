-module(chord_tests).
-include_lib("eunit/include/eunit.hrl").
-include("../include/chord.hrl").

%% Test hash generation and ID calculation
hash_test() ->
    % Test that hash function produces consistent results
    Hash1 = chord:hash("127.0.0.1:8001"),
    Hash2 = chord:hash("127.0.0.1:8001"),
    ?assertEqual(Hash1, Hash2),
    
    % Test that different inputs produce different hashes
    Hash3 = chord:hash("127.0.0.1:8002"),
    ?assertNotEqual(Hash1, Hash3),
    
    % Test that hash is within valid range (0 to 2^160 - 1)
    MaxValue = round(math:pow(2, 160)) - 1,
    ?assert(Hash1 >= 0),
    ?assert(Hash1 =< MaxValue).

%% Test node ID generation
node_id_test() ->
    NodeId1 = chord:generate_node_id("127.0.0.1", 8001),
    NodeId2 = chord:generate_node_id("127.0.0.1", 8002),
    
    ?assertNotEqual(NodeId1, NodeId2),
    ?assert(is_integer(NodeId1)),
    ?assert(is_integer(NodeId2)).

%% Test key-to-node mapping
key_belongs_to_test() ->
    NodeId = 100,
    PredId = 50,
    
    % Key between predecessor and node
    ?assert(chord:key_belongs_to(75, PredId, NodeId)),
    
    % Key equal to node ID (belongs to this node)
    ?assert(chord:key_belongs_to(100, PredId, NodeId)),
    
    % Key outside range
    ?assertNot(chord:key_belongs_to(30, PredId, NodeId)),
    ?assertNot(chord:key_belongs_to(120, PredId, NodeId)),
    
    % Test wrap-around case (predecessor > node)
    ?assert(chord:key_belongs_to(10, 200, 50)),
    ?assert(chord:key_belongs_to(230, 200, 50)),
    ?assertNot(chord:key_belongs_to(100, 200, 50)).

%% Test between function for circular ID space
between_test() ->
    % Normal case: a < b
    ?assert(chord:between(5, 3, 10)),
    ?assert(chord:between(7, 3, 10)),
    ?assertNot(chord:between(2, 3, 10)),
    ?assertNot(chord:between(11, 3, 10)),
    
    % Wrap-around case: a > b
    ?assert(chord:between(1, 10, 3)),
    ?assert(chord:between(11, 10, 3)),
    ?assertNot(chord:between(5, 10, 3)).

%% Test finger table initialization
init_finger_table_test() ->
    NodeId = chord:hash("127.0.0.1:8001"),
    FingerTable = chord:init_finger_table(NodeId),
    
    ?assertEqual(length(FingerTable), ?FINGER_TABLE_SIZE),
    
    % Check first finger entry
    FirstFinger = hd(FingerTable),
    ?assertEqual(FirstFinger#finger_entry.start, (NodeId + 1) rem round(math:pow(2, ?M))),
    
    % Check that intervals are correct
    lists:foreach(fun(I) ->
        Finger = lists:nth(I, FingerTable),
        Start = (NodeId + round(math:pow(2, I-1))) rem round(math:pow(2, ?M)),
        ?assertEqual(Finger#finger_entry.start, Start)
    end, lists:seq(1, ?FINGER_TABLE_SIZE)).

%% Test successor finding - simplified version
find_successor_test() ->
    % Create a single node for basic testing
    {ok, Node1} = chord:start_link(8001),
    timer:sleep(100),
    
    % Get node ID
    Id1 = chord:get_id(Node1),
    
    % Test finding successor for a key
    % Since we only have one node, it should return itself as successor
    TestKey = <<"test_key">>,
    Successor1 = chord:find_successor(Node1, TestKey),
    
    % Verify successor is correct (should be self in single-node ring)
    ?assert(is_record(Successor1, node_info)),
    ?assertEqual(Id1, Successor1#node_info.id),
    
    % Clean up
    chord:stop(Node1).

%% Test stabilization - simplified
stabilization_test() ->
    % For now, just test single node stabilization
    {ok, Node1} = chord:start_link(7001),
    timer:sleep(2000), % Wait for stabilization
    
    % In single node, successor should be self
    Successor1 = chord:get_successor(Node1),
    Id1 = chord:get_id(Node1),
    
    ?assertEqual(Successor1#node_info.id, Id1),
    
    % Clean up
    chord:stop(Node1).

%% Test finger table update - simplified
fix_fingers_test() ->
    % Start a single node
    {ok, Node1} = chord:start_link(6001),
    timer:sleep(3000), % Wait for finger fixing
    
    % Get finger table
    FingerTable1 = chord:get_finger_table(Node1),
    
    % Verify finger table structure
    ?assertEqual(length(FingerTable1), ?FINGER_TABLE_SIZE),
    
    % In single node ring, fingers should point to self
    Id1 = chord:get_id(Node1),
    HasSelfInFingers = lists:any(fun(#finger_entry{node = N}) ->
        N =/= undefined andalso N#node_info.id =:= Id1
    end, FingerTable1),
    
    ?assert(HasSelfInFingers),
    
    % Clean up
    chord:stop(Node1).

%% Test successor list maintenance
successor_list_test() ->
    % Start multiple nodes
    {ok, Node1} = chord:start_link(5001),
    timer:sleep(100),
    
    {ok, Node2} = chord:start_link(5002, {"127.0.0.1", 5001}),
    timer:sleep(500),
    
    {ok, Node3} = chord:start_link(5003, {"127.0.0.1", 5001}),
    timer:sleep(500),
    
    {ok, Node4} = chord:start_link(5004, {"127.0.0.1", 5001}),
    timer:sleep(2000), % Wait for stabilization
    
    % Get successor list from Node1
    SuccList = chord:get_successor_list(Node1),
    
    % Should have at least SUCCESSOR_LIST_SIZE entries (or total nodes - 1 if less)
    ExpectedSize = min(?SUCCESSOR_LIST_SIZE, 3), % We have 4 nodes total
    ?assert(length(SuccList) >= ExpectedSize),
    
    % All entries should be valid node_info records
    lists:foreach(fun(N) ->
        ?assert(is_record(N, node_info))
    end, SuccList),
    
    % Clean up
    chord:stop(Node1),
    chord:stop(Node2),
    chord:stop(Node3),
    chord:stop(Node4).

%% Test node join
node_join_test() ->
    % Start initial node
    {ok, Node1} = chord:start_link(4001),
    timer:sleep(100),
    
    % Add a key to Node1
    TestKey = <<"test_key">>,
    TestValue = <<"test_value">>,
    chord:put(Node1, TestKey, TestValue),
    
    % Start second node and join
    {ok, Node2} = chord:start_link(4002, {"127.0.0.1", 4001}),
    timer:sleep(3000), % Wait for join and key transfer
    
    % The key should be accessible from both nodes
    {ok, Value1} = chord:get(Node1, TestKey),
    {ok, Value2} = chord:get(Node2, TestKey),
    
    ?assertEqual(TestValue, Value1),
    ?assertEqual(TestValue, Value2),
    
    % Clean up
    chord:stop(Node1),
    chord:stop(Node2).

%% Test data migration on join
data_migration_test() ->
    % Start first node
    {ok, Node1} = chord:start_link(3001),
    timer:sleep(100),
    
    % Add multiple keys
    Keys = [<<"key", (integer_to_binary(I))/binary>> || I <- lists:seq(1, 10)],
    Values = [<<"value", (integer_to_binary(I))/binary>> || I <- lists:seq(1, 10)],
    
    lists:foreach(fun({K, V}) ->
        chord:put(Node1, K, V)
    end, lists:zip(Keys, Values)),
    
    % Start second node
    {ok, Node2} = chord:start_link(3002, {"127.0.0.1", 3001}),
    timer:sleep(3000), % Wait for stabilization and data migration
    
    % Check that all keys are still accessible
    lists:foreach(fun({K, V}) ->
        % Try to get from both nodes
        Result1 = chord:get(Node1, K),
        Result2 = chord:get(Node2, K),
        
        % At least one should have the key
        ?assert(Result1 =:= {ok, V} orelse Result2 =:= {ok, V})
    end, lists:zip(Keys, Values)),
    
    % Clean up
    chord:stop(Node1),
    chord:stop(Node2).

%% Test fault tolerance with node failure
node_failure_test() ->
    % Start 3-node ring
    {ok, Node1} = chord:start_link(2001),
    timer:sleep(100),
    
    {ok, Node2} = chord:start_link(2002, {"127.0.0.1", 2001}),
    timer:sleep(500),
    
    {ok, Node3} = chord:start_link(2003, {"127.0.0.1", 2001}),
    timer:sleep(2000), % Wait for stabilization
    
    % Add data
    TestKey = <<"failure_test_key">>,
    TestValue = <<"failure_test_value">>,
    chord:put(Node1, TestKey, TestValue),
    timer:sleep(500),
    
    % Kill Node2
    chord:stop(Node2),
    timer:sleep(3000), % Wait for failure detection and recovery
    
    % Data should still be accessible from remaining nodes
    Result1 = chord:get(Node1, TestKey),
    Result3 = chord:get(Node3, TestKey),
    
    ?assert(Result1 =:= {ok, TestValue} orelse Result3 =:= {ok, TestValue}),
    
    % Clean up
    chord:stop(Node1),
    chord:stop(Node3).

%% Test closest preceding node
closest_preceding_node_test() ->
    NodeId = 100,
    
    % Create a finger table with some entries
    FingerTable = [
        #finger_entry{start = 101, node = #node_info{id = 110}},
        #finger_entry{start = 102, node = #node_info{id = 110}},
        #finger_entry{start = 104, node = #node_info{id = 120}},
        #finger_entry{start = 108, node = #node_info{id = 140}},
        #finger_entry{start = 116, node = #node_info{id = 180}}
    ],
    
    % Test finding closest preceding node for key 150
    ClosestNode = chord:closest_preceding_node(NodeId, 150, FingerTable),
    ?assertEqual(140, ClosestNode#node_info.id),
    
    % Test for key 115
    ClosestNode2 = chord:closest_preceding_node(NodeId, 115, FingerTable),
    ?assertEqual(110, ClosestNode2#node_info.id).

%% Test concurrent operations
concurrent_operations_test() ->
    % Start nodes
    {ok, Node1} = chord:start_link(1001),
    timer:sleep(100),
    
    {ok, Node2} = chord:start_link(1002, {"127.0.0.1", 1001}),
    timer:sleep(2000),
    
    % Spawn multiple processes doing concurrent operations
    Parent = self(),
    NumProcesses = 20,
    
    Pids = [spawn(fun() ->
        Key = <<"concurrent_", (integer_to_binary(I))/binary>>,
        Value = <<"value_", (integer_to_binary(I))/binary>>,
        
        % Randomly choose a node to write to
        Node = case I rem 2 of
            0 -> Node1;
            1 -> Node2
        end,
        
        chord:put(Node, Key, Value),
        timer:sleep(100),
        {ok, Retrieved} = chord:get(Node, Key),
        
        Parent ! {done, I, Retrieved =:= Value}
    end) || I <- lists:seq(1, NumProcesses)],
    
    % Wait for all processes
    Results = [receive {done, I, Success} -> {I, Success} end || _ <- Pids],
    
    % All operations should succeed
    lists:foreach(fun({_I, Success}) ->
        ?assert(Success)
    end, Results),
    
    % Clean up
    chord:stop(Node1),
    chord:stop(Node2).