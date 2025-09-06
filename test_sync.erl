#!/usr/bin/env escript
%%! -pa ebin

-include("include/chord.hrl").

main([]) ->
    io:format("Testing replica synchronization...~n~n"),
    
    % Start 3 nodes
    {ok, Node1} = chord:start_link(8001),
    {ok, Node2} = chord:start_link(8002),
    {ok, Node3} = chord:start_link(8003),
    
    % Create ring
    ok = chord:create_ring(Node1),
    timer:sleep(500),
    
    % Join Node2
    ok = chord:join_ring(Node2, "localhost", 8001),
    timer:sleep(2000),
    
    % Store data before Node3 joins
    io:format("Storing data with 2 nodes...~n"),
    chord:put(Node1, <<"key1">>, <<"value1">>),
    chord:put(Node1, <<"key2">>, <<"value2">>),
    timer:sleep(1000),
    
    % Check initial distribution
    io:format("~nInitial distribution (2 nodes):~n"),
    check_key_distribution([Node1, Node2]),
    
    % Now join Node3
    io:format("~nJoining Node3...~n"),
    ok = chord:join_ring(Node3, "localhost", 8001),
    timer:sleep(3000),
    
    % Wait for synchronization
    io:format("~nWaiting for replica synchronization (6 seconds)...~n"),
    timer:sleep(6000),
    
    % Check distribution after sync
    io:format("~nDistribution after Node3 joins and sync:~n"),
    check_key_distribution([Node1, Node2, Node3]),
    
    % Test sync after failure and recovery
    io:format("~n=== Testing sync after temporary failure ===~n"),
    
    % Add new data
    chord:put(Node1, <<"key3">>, <<"value3">>),
    timer:sleep(1000),
    
    % Simulate Node2 being temporarily unavailable (but not stopped)
    % by directly deleting a key from its store
    {ok, State2} = gen_server:call(Node2, get_state),
    Store2 = State2#chord_state.kvs_store,
    kvs_store:delete(Store2, <<"key3">>),
    
    io:format("Removed key3 from Node2 (simulating missed replication)~n"),
    check_key_distribution([Node1, Node2, Node3]),
    
    % Wait for sync to repair
    io:format("~nWaiting for sync to repair (6 seconds)...~n"),
    timer:sleep(6000),
    
    io:format("~nDistribution after sync repair:~n"),
    check_key_distribution([Node1, Node2, Node3]),
    
    % Clean up
    chord:stop(Node1),
    chord:stop(Node2),
    chord:stop(Node3),
    
    io:format("~nTest complete.~n").

check_key_distribution(Nodes) ->
    lists:foreach(fun(Node) ->
        {ok, State} = gen_server:call(Node, get_state),
        NodeId = State#chord_state.self#node_info.id,
        Store = State#chord_state.kvs_store,
        {ok, Keys} = kvs_store:list_keys(Store),
        
        io:format("  Node ~p: ", [NodeId rem 1000000]),
        lists:foreach(fun(K) ->
            io:format("~s ", [K])
        end, Keys),
        io:format("(~p keys)~n", [length(Keys)])
    end, Nodes).