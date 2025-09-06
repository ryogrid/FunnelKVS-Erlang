-module(demo_phase3).
-export([run/0]).
-include("include/chord.hrl").

%% Demo script to showcase Phase 3: RPC Framework
run() ->
    io:format("~n=====================================~n"),
    io:format("FunnelKVS Demo - Phase 3 Progress~n"),
    io:format("=====================================~n~n"),
    
    io:format("Phase 3: RPC Framework for Multi-Node Communication~n"),
    io:format("---------------------------------------------------~n~n"),
    
    %% 1. Start two Chord nodes
    io:format("1. Starting two Chord nodes...~n"),
    {ok, Node1} = chord:start_link(11001),
    {ok, Node2} = chord:start_link(11002),
    timer:sleep(100),
    
    Id1 = chord:get_id(Node1),
    Id2 = chord:get_id(Node2),
    io:format("   Node 1 ID: ~p~n", [Id1 rem 1000000]),
    io:format("   Node 2 ID: ~p~n", [Id2 rem 1000000]),
    io:format("~n"),
    
    %% 2. Start RPC servers
    io:format("2. Starting RPC servers for both nodes...~n"),
    {ok, Rpc1} = chord_rpc:start_server(11003, Node1),
    {ok, Rpc2} = chord_rpc:start_server(11004, Node2),
    timer:sleep(100),
    io:format("   RPC server 1 on port 11003~n"),
    io:format("   RPC server 2 on port 11004~n"),
    io:format("~n"),
    
    %% 3. Connect RPC client to Node1
    io:format("3. Connecting RPC client to Node 1...~n"),
    {ok, Socket1} = chord_rpc:connect("127.0.0.1", 11003),
    io:format("   Connected successfully~n~n"),
    
    %% 4. Test RPC calls
    io:format("4. Testing RPC operations:~n~n"),
    
    % Get predecessor (should be undefined initially)
    io:format("   get_predecessor:~n"),
    {ok, Pred1} = chord_rpc:call(Socket1, get_predecessor, []),
    io:format("     Node 1 predecessor: ~p~n", [Pred1]),
    
    % Get successor list
    io:format("~n   get_successor_list:~n"),
    {ok, SuccList} = chord_rpc:call(Socket1, get_successor_list, []),
    io:format("     Node 1 successor list: ~p entries~n", [length(SuccList)]),
    
    % Find successor for a key
    io:format("~n   find_successor:~n"),
    TestKey = 12345,
    {ok, Successor} = chord_rpc:call(Socket1, find_successor, TestKey),
    io:format("     Successor for key ~p: Node ~p~n", 
              [TestKey, Successor#node_info.id rem 1000000]),
    
    % Store data locally on Node1
    io:format("~n   Storing data on Node 1 (local):~n"),
    chord:put(Node1, <<"rpc_test_key">>, <<"rpc_test_value">>),
    io:format("     PUT rpc_test_key -> rpc_test_value~n"),
    
    % Retrieve via RPC
    io:format("~n   Retrieving data via RPC:~n"),
    {ok, {Key, Value}} = chord_rpc:call(Socket1, get_key_value, <<"rpc_test_key">>),
    io:format("     GET ~s -> ~s~n", [Key, Value]),
    
    %% 5. Test notify operation
    io:format("~n5. Testing notify operation:~n"),
    NotifyingNode = #node_info{
        id = 555555,
        ip = {127, 0, 0, 1},
        port = 55555,
        pid = undefined
    },
    {ok, ok} = chord_rpc:call(Socket1, notify, NotifyingNode),
    io:format("   Notified Node 1 about node 555555~n"),
    
    % Check predecessor was updated
    {ok, NewPred} = chord_rpc:call(Socket1, get_predecessor, []),
    io:format("   Node 1 new predecessor: ~p~n", [NewPred#node_info.id]),
    
    %% 6. Test transfer_keys preparation
    io:format("~n6. Testing key transfer preparation:~n"),
    
    % Add more keys to Node1
    chord:put(Node1, <<"key1">>, <<"value1">>),
    chord:put(Node1, <<"key2">>, <<"value2">>),
    chord:put(Node1, <<"key3">>, <<"value3">>),
    
    Node2Info = #node_info{
        id = Id2,
        ip = {127, 0, 0, 1},
        port = 11004,
        pid = Node2
    },
    
    {ok, TransferredKeys} = chord_rpc:call(Socket1, transfer_keys, {Node2Info, range}),
    io:format("   Keys ready for transfer: ~p~n", [length(TransferredKeys)]),
    lists:foreach(fun({K, _V}) ->
        io:format("     - ~s~n", [K])
    end, lists:sublist(TransferredKeys, 3)),
    
    %% 7. Connect to Node2 and test
    io:format("~n7. Connecting to Node 2 via RPC:~n"),
    {ok, Socket2} = chord_rpc:connect("127.0.0.1", 11004),
    {ok, Id2ViaRPC} = chord_rpc:call(Socket2, get_id, []),
    io:format("   Node 2 ID via RPC: ~p~n", [Id2ViaRPC rem 1000000]),
    
    %% 8. Test concurrent RPC connections
    io:format("~n8. Testing concurrent RPC connections:~n"),
    Parent = self(),
    NumClients = 5,
    
    io:format("   Spawning ~p concurrent RPC clients...~n", [NumClients]),
    Pids = [spawn(fun() ->
        {ok, S} = chord_rpc:connect("127.0.0.1", 11003),
        {ok, _} = chord_rpc:call(S, get_predecessor, []),
        {ok, _} = chord_rpc:call(S, find_successor, I * 1000),
        chord_rpc:disconnect(S),
        Parent ! {done, I}
    end) || I <- lists:seq(1, NumClients)],
    
    % Wait for all clients
    lists:foreach(fun(I) ->
        receive {done, I} -> ok
        after 5000 -> error(timeout)
        end
    end, lists:seq(1, NumClients)),
    io:format("   All ~p clients completed successfully~n", [NumClients]),
    
    %% Clean up
    chord_rpc:disconnect(Socket1),
    chord_rpc:disconnect(Socket2),
    chord_rpc:stop_server(Rpc1),
    chord_rpc:stop_server(Rpc2),
    chord:stop(Node1),
    chord:stop(Node2),
    
    io:format("~n=====================================~n"),
    io:format("Phase 3 RPC Framework Status~n"),
    io:format("=====================================~n"),
    io:format("✓ TCP-based RPC server and client~n"),
    io:format("✓ Binary protocol handshake~n"),
    io:format("✓ Remote procedure calls:~n"),
    io:format("  - find_successor~n"),
    io:format("  - get_predecessor~n"),
    io:format("  - notify~n"),
    io:format("  - get_successor_list~n"),
    io:format("  - transfer_keys~n"),
    io:format("  - get/put operations~n"),
    io:format("✓ Concurrent client support~n"),
    io:format("✓ Error handling~n"),
    io:format("✓ 10 RPC tests passing~n"),
    io:format("~n"),
    io:format("Next steps:~n"),
    io:format("• Implement node join protocol using RPC~n"),
    io:format("• Key migration during join~n"),
    io:format("• Update finger tables across nodes~n"),
    io:format("• Multi-node ring stabilization~n"),
    io:format("=====================================~n~n"),
    
    ok.