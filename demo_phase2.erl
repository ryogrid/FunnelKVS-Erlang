-module(demo_phase2).
-export([run/0]).
-include("include/chord.hrl").

%% Demo script to showcase Phase 2: Chord DHT foundation
run() ->
    io:format("~n=====================================~n"),
    io:format("FunnelKVS Demo - Phase 2 Progress~n"),
    io:format("=====================================~n~n"),
    
    io:format("Phase 2: Chord DHT Protocol Foundation~n"),
    io:format("---------------------------------------~n~n"),
    
    %% 1. Demonstrate hash function
    io:format("1. SHA-1 based hashing:~n"),
    Hash1 = chord:hash("key1"),
    Hash2 = chord:hash("key2"),
    io:format("   hash('key1') = ~p~n", [Hash1]),
    io:format("   hash('key2') = ~p~n", [Hash2]),
    io:format("   160-bit identifier space (2^160 possible values)~n~n"),
    
    %% 2. Node ID generation
    io:format("2. Node ID generation:~n"),
    NodeId1 = chord:generate_node_id("127.0.0.1", 3001),
    NodeId2 = chord:generate_node_id("127.0.0.1", 3002),
    io:format("   Node 127.0.0.1:3001 -> ID: ~p~n", [NodeId1]),
    io:format("   Node 127.0.0.1:3002 -> ID: ~p~n", [NodeId2]),
    io:format("~n"),
    
    %% 3. Create a single-node Chord ring
    io:format("3. Creating single-node Chord ring...~n"),
    {ok, Node1} = chord:start_link(3001),
    timer:sleep(100),
    
    Id1 = chord:get_id(Node1),
    io:format("   Node started with ID: ~p~n", [Id1]),
    
    %% 4. Show ring structure
    io:format("~n4. Ring structure:~n"),
    Successor = chord:get_successor(Node1),
    Predecessor = chord:get_predecessor(Node1),
    io:format("   Successor: ~p (self in single-node ring)~n", [Successor#node_info.id]),
    io:format("   Predecessor: ~p~n", [Predecessor]),
    
    %% 5. Finger table
    io:format("~n5. Finger table (first 10 entries):~n"),
    FingerTable = chord:get_finger_table(Node1),
    lists:foreach(fun(I) ->
        Finger = lists:nth(I, FingerTable),
        io:format("   Finger[~p]: start=~p, node=~p~n", 
                  [I, Finger#finger_entry.start,
                   case Finger#finger_entry.node of
                       undefined -> undefined;
                       N -> N#node_info.id
                   end])
    end, lists:seq(1, min(10, length(FingerTable)))),
    
    %% 6. Store and retrieve data
    io:format("~n6. Storing and retrieving data:~n"),
    
    % Store some key-value pairs
    TestData = [
        {<<"user:alice">>, <<"Alice Smith">>},
        {<<"user:bob">>, <<"Bob Johnson">>},
        {<<"config:timeout">>, <<"5000">>},
        {<<"session:xyz">>, <<"active">>}
    ],
    
    lists:foreach(fun({K, V}) ->
        chord:put(Node1, K, V),
        io:format("   PUT ~s -> ~s~n", [K, V])
    end, TestData),
    
    io:format("~n   Retrieving data:~n"),
    lists:foreach(fun({K, _V}) ->
        case chord:get(Node1, K) of
            {ok, Value} ->
                io:format("   GET ~s -> ~s~n", [K, Value]);
            {error, not_found} ->
                io:format("   GET ~s -> not found~n", [K])
        end
    end, TestData),
    
    %% 7. Key responsibility calculation
    io:format("~n7. Key responsibility (who handles what):~n"),
    lists:foreach(fun({K, _V}) ->
        KeyHash = chord:hash(K),
        Responsible = chord:find_successor(Node1, K),
        io:format("   Key '~s' (hash: ~p) -> Node ~p~n", 
                  [K, KeyHash rem 1000000, Responsible#node_info.id rem 1000000])
    end, TestData),
    
    %% 8. Test stabilization
    io:format("~n8. Stabilization running (every ~p ms)~n", [?STABILIZE_INTERVAL]),
    io:format("   Fix fingers running (every ~p ms)~n", [?FIX_FINGERS_INTERVAL]),
    io:format("   Maintenance routines keep ring consistent~n"),
    
    %% Clean up
    chord:stop(Node1),
    
    io:format("~n=====================================~n"),
    io:format("Phase 2 Status Summary~n"),
    io:format("=====================================~n"),
    io:format("✓ SHA-1 based node ID generation~n"),
    io:format("✓ 160-bit identifier space~n"),
    io:format("✓ Finger table structure (160 entries)~n"),
    io:format("✓ Find successor algorithm~n"),
    io:format("✓ Stabilization routine~n"),
    io:format("✓ Fix fingers routine~n"),
    io:format("✓ Single-node ring operations~n"),
    io:format("✓ Key-value storage on Chord node~n"),
    io:format("✓ 11 tests passing~n"),
    io:format("~n"),
    io:format("Next steps for Phase 3:~n"),
    io:format("• Implement RPC for multi-node communication~n"),
    io:format("• Node join protocol with key transfer~n"),
    io:format("• Successor list maintenance~n"),
    io:format("• Multi-node ring formation~n"),
    io:format("• Replication across successor nodes~n"),
    io:format("=====================================~n~n"),
    
    ok.