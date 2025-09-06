#!/usr/bin/env escript
%%! -pa ebin

-include("include/chord.hrl").

main([]) ->
    io:format("Debug quorum test...~n~n"),
    
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
    
    % Check successor lists
    io:format("Checking successor lists:~n"),
    SuccList1 = chord:get_successor_list(Node1),
    io:format("  Node1 successors: ~p nodes~n", [length(SuccList1)]),
    
    SuccList2 = chord:get_successor_list(Node2),
    io:format("  Node2 successors: ~p nodes~n", [length(SuccList2)]),
    
    SuccList3 = chord:get_successor_list(Node3),
    io:format("  Node3 successors: ~p nodes~n", [length(SuccList3)]),
    
    % Test storing a key and see where it goes
    io:format("~nStoring test key:~n"),
    Key = <<"test">>,
    KeyHash = chord:hash(Key),
    io:format("  Key hash: ~p~n", [KeyHash]),
    
    % Find which node is responsible
    {ok, State1} = gen_server:call(Node1, get_state),
    {ok, State2} = gen_server:call(Node2, get_state),
    {ok, State3} = gen_server:call(Node3, get_state),
    
    Id1 = State1#chord_state.self#node_info.id,
    Id2 = State2#chord_state.self#node_info.id,
    Id3 = State3#chord_state.self#node_info.id,
    
    io:format("  Node IDs:~n"),
    io:format("    Node1: ~p~n", [Id1]),
    io:format("    Node2: ~p~n", [Id2]),
    io:format("    Node3: ~p~n", [Id3]),
    
    % Now try quorum put
    io:format("~nTrying quorum put:~n"),
    Result = chord:put(Node1, Key, <<"value">>, quorum),
    io:format("  Result: ~p~n", [Result]),
    
    % Check which nodes have the key
    timer:sleep(1000),
    io:format("~nChecking key distribution:~n"),
    Store1 = State1#chord_state.kvs_store,
    Store2 = State2#chord_state.kvs_store,
    Store3 = State3#chord_state.kvs_store,
    
    case kvs_store:get(Store1, Key) of
        {ok, V1} -> io:format("  Node1 has key: ~p~n", [V1]);
        _ -> io:format("  Node1 does not have key~n")
    end,
    
    case kvs_store:get(Store2, Key) of
        {ok, V2} -> io:format("  Node2 has key: ~p~n", [V2]);
        _ -> io:format("  Node2 does not have key~n")
    end,
    
    case kvs_store:get(Store3, Key) of
        {ok, V3} -> io:format("  Node3 has key: ~p~n", [V3]);
        _ -> io:format("  Node3 does not have key~n")
    end,
    
    % Clean up
    chord:stop(Node1),
    chord:stop(Node2),
    chord:stop(Node3),
    
    io:format("~nDone.~n").