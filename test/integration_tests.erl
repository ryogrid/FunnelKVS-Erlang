-module(integration_tests).
-include_lib("eunit/include/eunit.hrl").

%% Full end-to-end integration tests

integration_test_() ->
    {timeout, 30, fun full_system_test/0}.

full_system_test() ->
    Port = 7777,
    
    % Start server
    {ok, ServerPid} = funnelkvs_server:start_link(Port),
    timer:sleep(200),
    
    try
        % Test 1: Basic client operations
        {ok, Client1} = funnelkvs_client:connect("localhost", Port),
        
        % PUT operations
        ?assertEqual(ok, funnelkvs_client:put(Client1, <<"user:1">>, <<"John Doe">>)),
        ?assertEqual(ok, funnelkvs_client:put(Client1, <<"user:2">>, <<"Jane Smith">>)),
        ?assertEqual(ok, funnelkvs_client:put(Client1, <<"config:timeout">>, <<"5000">>)),
        
        % GET operations
        ?assertEqual({ok, <<"John Doe">>}, funnelkvs_client:get(Client1, <<"user:1">>)),
        ?assertEqual({ok, <<"Jane Smith">>}, funnelkvs_client:get(Client1, <<"user:2">>)),
        ?assertEqual({ok, <<"5000">>}, funnelkvs_client:get(Client1, <<"config:timeout">>)),
        
        % Non-existent key
        ?assertEqual({error, not_found}, funnelkvs_client:get(Client1, <<"nonexistent">>)),
        
        % DELETE operation
        ?assertEqual(ok, funnelkvs_client:delete(Client1, <<"user:2">>)),
        ?assertEqual({error, not_found}, funnelkvs_client:get(Client1, <<"user:2">>)),
        
        % Ping test
        ?assertEqual({ok, <<"pong">>}, funnelkvs_client:ping(Client1)),
        
        % Stats test
        {ok, StatsData} = funnelkvs_client:stats(Client1),
        ?assert(is_binary(StatsData)),
        
        % Test 2: Multiple concurrent clients
        {ok, Client2} = funnelkvs_client:connect("localhost", Port),
        {ok, Client3} = funnelkvs_client:connect("localhost", Port),
        
        % Client 2 can see data from Client 1
        ?assertEqual({ok, <<"John Doe">>}, funnelkvs_client:get(Client2, <<"user:1">>)),
        
        % Client 3 adds new data
        ?assertEqual(ok, funnelkvs_client:put(Client3, <<"session:abc123">>, <<"active">>)),
        
        % Client 1 can see data from Client 3
        ?assertEqual({ok, <<"active">>}, funnelkvs_client:get(Client1, <<"session:abc123">>)),
        
        % Test 3: Large data
        LargeKey = <<"large_data">>,
        LargeValue = binary:copy(<<"Hello World! ">>, 1000), % ~13KB
        ?assertEqual(ok, funnelkvs_client:put(Client1, LargeKey, LargeValue)),
        {ok, Retrieved} = funnelkvs_client:get(Client2, LargeKey),
        ?assertEqual(LargeValue, Retrieved),
        
        % Test 4: Binary data with special characters
        BinaryKey = <<255, 254, 253, 0, 1, 2, 3>>,
        BinaryValue = <<0, 255, 128, 64, 32, 16, 8, 4, 2, 1>>,
        ?assertEqual(ok, funnelkvs_client:put(Client1, BinaryKey, BinaryValue)),
        ?assertEqual({ok, BinaryValue}, funnelkvs_client:get(Client3, BinaryKey)),
        
        % Test 5: Stress test with many operations
        NumOps = 100,
        lists:foreach(fun(N) ->
            Key = <<"stress_", (integer_to_binary(N))/binary>>,
            Value = <<"value_", (integer_to_binary(N * N))/binary>>,
            ?assertEqual(ok, funnelkvs_client:put(Client1, Key, Value))
        end, lists:seq(1, NumOps)),
        
        % Verify all stress test data
        lists:foreach(fun(N) ->
            Key = <<"stress_", (integer_to_binary(N))/binary>>,
            ExpectedValue = <<"value_", (integer_to_binary(N * N))/binary>>,
            ?assertEqual({ok, ExpectedValue}, funnelkvs_client:get(Client2, Key))
        end, lists:seq(1, NumOps)),
        
        % Test 6: Connection resilience (disconnect and reconnect)
        funnelkvs_client:disconnect(Client2),
        {ok, Client4} = funnelkvs_client:connect("localhost", Port),
        
        % Data should still be available after reconnection
        ?assertEqual({ok, <<"John Doe">>}, funnelkvs_client:get(Client4, <<"user:1">>)),
        ?assertEqual({ok, <<"active">>}, funnelkvs_client:get(Client4, <<"session:abc123">>)),
        
        % Clean up clients
        funnelkvs_client:disconnect(Client1),
        funnelkvs_client:disconnect(Client3),
        funnelkvs_client:disconnect(Client4),
        
        io:format("Integration test completed successfully!~n")
        
    after
        % Clean up server
        funnelkvs_server:stop(ServerPid)
    end.

%% Test the CLI functionality (basic smoke test)
cli_smoke_test() ->
    Port = 7776,
    {ok, ServerPid} = funnelkvs_server:start_link(Port),
    timer:sleep(100),
    
    try
        % Just test that the client module loads and CLI functions exist
        ?assert(erlang:function_exported(funnelkvs_client, start, 0)),
        
        % Test command parsing
        ?assertEqual({get, "mykey"}, funnelkvs_client:parse_command("get mykey")),
        ?assertEqual({put, "key", "value with spaces"}, 
                     funnelkvs_client:parse_command("put key value with spaces")),
        ?assertEqual({delete, "key"}, funnelkvs_client:parse_command("delete key")),
        ?assertEqual(ping, funnelkvs_client:parse_command("ping")),
        ?assertEqual(stats, funnelkvs_client:parse_command("stats")),
        ?assertEqual(quit, funnelkvs_client:parse_command("quit")),
        ?assertEqual(help, funnelkvs_client:parse_command("help"))
        
    after
        funnelkvs_server:stop(ServerPid)
    end.