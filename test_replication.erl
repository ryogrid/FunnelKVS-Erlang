#!/usr/bin/env escript
%%! -pa ebin

-include("include/chord.hrl").

main([]) ->
    io:format("Testing successor-list replication (N=3)...~n~n"),
    
    % Start 4 nodes for testing
    {ok, Node1} = chord:start_link(8001),
    {ok, Node2} = chord:start_link(8002),
    {ok, Node3} = chord:start_link(8003),
    {ok, Node4} = chord:start_link(8004),
    
    % Get node IDs
    Id1 = chord:get_id(Node1),
    Id2 = chord:get_id(Node2),
    Id3 = chord:get_id(Node3),
    Id4 = chord:get_id(Node4),
    
    io:format("Nodes started:~n"),
    io:format("  Node1: ~p~n", [Id1]),
    io:format("  Node2: ~p~n", [Id2]),
    io:format("  Node3: ~p~n", [Id3]),
    io:format("  Node4: ~p~n", [Id4]),
    
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
    
    % Store test data through Node1
    io:format("~nStoring test data...~n"),
    TestKeys = [
        {<<"key1">>, <<"value1">>},
        {<<"key2">>, <<"value2">>},
        {<<"key3">>, <<"value3">>},
        {<<"key4">>, <<"value4">>}
    ],
    
    lists:foreach(fun({K, V}) ->
        case chord:put(Node1, K, V) of
            ok -> io:format("  Stored: ~s -> ~s~n", [K, V]);
            {ok, ok} -> io:format("  Stored: ~s -> ~s~n", [K, V]);
            Error -> io:format("  Failed to store ~s: ~p~n", [K, Error])
        end
    end, TestKeys),
    
    % Wait for replication
    io:format("~nWaiting for replication to complete (2 seconds)...~n"),
    timer:sleep(2000),
    
    % Check data distribution
    io:format("~nChecking data distribution (replicas):~n"),
    check_replicas_on_all_nodes([Node1, Node2, Node3, Node4], TestKeys),
    
    % Test failure scenario
    io:format("~n=== Testing failure scenario ===~n"),
    io:format("Killing Node2...~n"),
    chord:stop(Node2),
    timer:sleep(2000),
    
    % Check data is still accessible
    io:format("~nChecking data accessibility after Node2 failure:~n"),
    lists:foreach(fun({K, _V}) ->
        case chord:get(Node1, K) of
            {ok, Value} ->
                io:format("  ~s: Accessible (value: ~s)~n", [K, Value]);
            _ ->
                io:format("  ~s: NOT ACCESSIBLE!~n", [K])
        end
    end, TestKeys),
    
    % Clean up
    chord:stop(Node1),
    chord:stop(Node3),
    chord:stop(Node4),
    
    io:format("~nTest complete.~n").

check_replicas_on_all_nodes(Nodes, Keys) ->
    lists:foreach(fun(Node) ->
        try
            {ok, State} = gen_server:call(Node, get_state, 1000),
            NodeId = State#chord_state.self#node_info.id,
            Store = State#chord_state.kvs_store,
            {ok, StoredKeys} = kvs_store:list_keys(Store),
            
            io:format("~nNode ~p stores ~p keys:~n", [NodeId rem 1000000, length(StoredKeys)]),
            lists:foreach(fun(K) ->
                case lists:keyfind(K, 1, Keys) of
                    {K, _V} -> io:format("  ~s~n", [K]);
                    _ -> io:format("  ~s (other)~n", [K])
                end
            end, StoredKeys)
        catch
            _:_ ->
                io:format("~nNode is dead~n")
        end
    end, Nodes).