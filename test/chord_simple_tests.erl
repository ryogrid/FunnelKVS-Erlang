-module(chord_simple_tests).
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

%% Test single node creation
single_node_test() ->
    {ok, Node1} = chord:start_link(9001),
    timer:sleep(100),
    
    % Get node ID
    Id1 = chord:get_id(Node1),
    ?assert(is_integer(Id1)),
    
    % Get successor (should be self in single-node ring)
    Successor = chord:get_successor(Node1),
    ?assertEqual(Id1, Successor#node_info.id),
    
    % Get predecessor (should be undefined initially)
    Pred = chord:get_predecessor(Node1),
    ?assertEqual(undefined, Pred),
    
    % Clean up
    chord:stop(Node1).

%% Test data operations on single node
single_node_data_test() ->
    {ok, Node1} = chord:start_link(9002),
    timer:sleep(100),
    
    % Test PUT operation (use eventual consistency for single node)
    Key = <<"test_key">>,
    Value = <<"test_value">>,
    ?assertEqual(ok, chord:put(Node1, Key, Value, eventual)),
    
    % Test GET operation (use eventual consistency for single node)
    ?assertEqual({ok, Value}, chord:get(Node1, Key, eventual)),
    
    % Test GET non-existent key
    ?assertEqual({error, not_found}, chord:get(Node1, <<"nonexistent">>, eventual)),
    
    % Test DELETE operation (use eventual consistency for single node)
    ?assertEqual(ok, chord:delete(Node1, Key, eventual)),
    ?assertEqual({error, not_found}, chord:get(Node1, Key, eventual)),
    
    % Clean up
    chord:stop(Node1).

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
    ?assertEqual(140, ClosestNode#node_info.id).

%% Test find successor on single node
find_successor_single_test() ->
    {ok, Node1} = chord:start_link(9003),
    timer:sleep(100),
    
    % Any key should return self as successor in single-node ring
    TestKey = <<"any_key">>,
    Successor = chord:find_successor(Node1, TestKey),
    
    Id1 = chord:get_id(Node1),
    ?assertEqual(Id1, Successor#node_info.id),
    
    % Clean up
    chord:stop(Node1).

%% Test stabilization on single node
stabilization_single_test() ->
    {ok, Node1} = chord:start_link(9004),
    timer:sleep(2000), % Wait for stabilization to run
    
    % Node should remain stable with self as successor
    Successor = chord:get_successor(Node1),
    Id1 = chord:get_id(Node1),
    ?assertEqual(Id1, Successor#node_info.id),
    
    % Clean up
    chord:stop(Node1).

%% Test multiple data operations
multiple_operations_test() ->
    {ok, Node1} = chord:start_link(9005),
    timer:sleep(100),
    
    % Add multiple key-value pairs
    Keys = [<<"key", (integer_to_binary(I))/binary>> || I <- lists:seq(1, 10)],
    Values = [<<"value", (integer_to_binary(I))/binary>> || I <- lists:seq(1, 10)],
    
    % PUT all pairs (use eventual consistency for single node)
    lists:foreach(fun({K, V}) ->
        ?assertEqual(ok, chord:put(Node1, K, V, eventual))
    end, lists:zip(Keys, Values)),
    
    % GET all pairs (use eventual consistency for single node)
    lists:foreach(fun({K, V}) ->
        ?assertEqual({ok, V}, chord:get(Node1, K, eventual))
    end, lists:zip(Keys, Values)),
    
    % DELETE some pairs (use eventual consistency for single node)
    lists:foreach(fun(K) ->
        ?assertEqual(ok, chord:delete(Node1, K, eventual))
    end, lists:sublist(Keys, 5)),
    
    % Verify deleted (use eventual consistency for single node)
    lists:foreach(fun(K) ->
        ?assertEqual({error, not_found}, chord:get(Node1, K, eventual))
    end, lists:sublist(Keys, 5)),
    
    % Verify remaining (use eventual consistency for single node)
    RemainingPairs = lists:zip(
        lists:sublist(Keys, 6, 5),
        lists:sublist(Values, 6, 5)
    ),
    lists:foreach(fun({K, V}) ->
        ?assertEqual({ok, V}, chord:get(Node1, K, eventual))
    end, RemainingPairs),
    
    % Clean up
    chord:stop(Node1).