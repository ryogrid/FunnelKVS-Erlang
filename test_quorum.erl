#!/usr/bin/env escript
%%! -pa ebin

-include("include/chord.hrl").

main([]) ->
    io:format("Testing quorum-based reads/writes (R=W=2, N=3)...~n~n"),
    
    % Start 4 nodes for testing
    {ok, Node1} = chord:start_link(8001),
    {ok, Node2} = chord:start_link(8002),
    {ok, Node3} = chord:start_link(8003),
    {ok, Node4} = chord:start_link(8004),
    
    % Create ring
    ok = chord:create_ring(Node1),
    timer:sleep(500),
    
    % Join nodes
    ok = chord:join_ring(Node2, "localhost", 8001),
    timer:sleep(2000),
    ok = chord:join_ring(Node3, "localhost", 8001),
    timer:sleep(2000),
    ok = chord:join_ring(Node4, "localhost", 8001),
    timer:sleep(3000),
    
    % Test 1: Quorum write
    io:format("Test 1: Quorum write~n"),
    io:format("  Writing with quorum consistency...~n"),
    case chord:put(Node1, <<"key1">>, <<"value1">>, quorum) of
        ok -> io:format("  SUCCESS: Quorum write succeeded~n");
        Error -> io:format("  FAILED: Quorum write error: ~p~n", [Error])
    end,
    
    % Test 2: Quorum read
    timer:sleep(1000),
    io:format("~nTest 2: Quorum read~n"),
    io:format("  Reading with quorum consistency...~n"),
    case chord:get(Node1, <<"key1">>, quorum) of
        {ok, <<"value1">>} -> io:format("  SUCCESS: Quorum read returned correct value~n");
        {ok, Value} -> io:format("  FAILED: Unexpected value: ~p~n", [Value]);
        Error2 -> io:format("  FAILED: Quorum read error: ~p~n", [Error2])
    end,
    
    % Test 3: Eventual consistency write and read
    io:format("~nTest 3: Eventual consistency operations~n"),
    case chord:put(Node1, <<"key2">>, <<"value2">>, eventual) of
        ok -> io:format("  Eventual write succeeded~n");
        Error3 -> io:format("  Eventual write error: ~p~n", [Error3])
    end,
    
    timer:sleep(500),
    case chord:get(Node1, <<"key2">>, eventual) of
        {ok, <<"value2">>} -> io:format("  Eventual read succeeded~n");
        Error4 -> io:format("  Eventual read error: ~p~n", [Error4])
    end,
    
    % Test 4: Quorum operation with node failure
    io:format("~nTest 4: Quorum with node failure~n"),
    io:format("  Storing key3 with quorum...~n"),
    chord:put(Node1, <<"key3">>, <<"value3">>, quorum),
    timer:sleep(1000),
    
    io:format("  Killing Node2...~n"),
    chord:stop(Node2),
    timer:sleep(2000),
    
    io:format("  Reading key3 with quorum (should still work with N-1 nodes)...~n"),
    case chord:get(Node1, <<"key3">>, quorum) of
        {ok, <<"value3">>} -> 
            io:format("  SUCCESS: Quorum read succeeded despite node failure~n");
        Error5 -> 
            io:format("  FAILED: Quorum read failed: ~p~n", [Error5])
    end,
    
    % Test 5: Quorum write with insufficient replicas
    io:format("~nTest 5: Quorum write with insufficient replicas~n"),
    io:format("  Killing Node3...~n"),
    chord:stop(Node3),
    timer:sleep(2000),
    
    io:format("  Attempting quorum write with only 2 nodes (insufficient for W=2)...~n"),
    case chord:put(Node1, <<"key4">>, <<"value4">>, quorum) of
        {error, insufficient_replicas} -> 
            io:format("  SUCCESS: Correctly rejected due to insufficient replicas~n");
        ok ->
            io:format("  WARNING: Write succeeded with insufficient replicas~n");
        Error6 ->
            io:format("  ERROR: Unexpected error: ~p~n", [Error6])
    end,
    
    % Clean up
    chord:stop(Node1),
    chord:stop(Node4),
    
    io:format("~nTest complete.~n").