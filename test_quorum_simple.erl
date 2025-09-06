#!/usr/bin/env escript
%%! -pa ebin

-include("include/chord.hrl").

main([]) ->
    io:format("Simple quorum test...~n~n"),
    
    % Start 3 nodes
    {ok, Node1} = chord:start_link(8001),
    {ok, Node2} = chord:start_link(8002),
    {ok, Node3} = chord:start_link(8003),
    
    % Create ring
    ok = chord:create_ring(Node1),
    timer:sleep(500),
    
    % Join nodes
    ok = chord:join_ring(Node2, "localhost", 8001),
    timer:sleep(2000),
    ok = chord:join_ring(Node3, "localhost", 8001),
    timer:sleep(3000),
    
    % Test eventual consistency first
    io:format("Testing eventual consistency:~n"),
    Result1 = chord:put(Node1, <<"test1">>, <<"val1">>, eventual),
    io:format("  Put result: ~p~n", [Result1]),
    timer:sleep(500),
    Result2 = chord:get(Node1, <<"test1">>, eventual),
    io:format("  Get result: ~p~n", [Result2]),
    
    % Now test quorum
    io:format("~nTesting quorum consistency:~n"),
    Result3 = chord:put(Node1, <<"test2">>, <<"val2">>, quorum),
    io:format("  Put result: ~p~n", [Result3]),
    timer:sleep(1000),
    Result4 = chord:get(Node1, <<"test2">>, quorum),
    io:format("  Get result: ~p~n", [Result4]),
    
    % Clean up
    chord:stop(Node1),
    chord:stop(Node2),
    chord:stop(Node3),
    
    io:format("~nDone.~n").