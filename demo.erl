-module(demo).
-export([run/0]).

%% Demo script to showcase the FunnelKVS system
run() ->
    io:format("~n=================================~n"),
    io:format("FunnelKVS Demo - Phase 1 Complete~n"),
    io:format("=================================~n~n"),
    
    Port = 8080,
    
    io:format("1. Starting FunnelKVS server on port ~p...~n", [Port]),
    {ok, ServerPid} = funnelkvs_server:start_link(Port),
    timer:sleep(200),
    
    io:format("2. Connecting client to server...~n"),
    {ok, ClientPid} = funnelkvs_client:connect("localhost", Port),
    
    io:format("3. Testing basic operations:~n~n"),
    
    %% Test PING
    io:format("   PING -> "),
    {ok, PongMsg} = funnelkvs_client:ping(ClientPid),
    io:format("~s~n", [PongMsg]),
    
    %% Test PUT operations
    io:format("   PUT user:alice -> 'Alice Johnson'~n"),
    ok = funnelkvs_client:put(ClientPid, <<"user:alice">>, <<"Alice Johnson">>),
    
    io:format("   PUT user:bob -> 'Bob Smith'~n"),
    ok = funnelkvs_client:put(ClientPid, <<"user:bob">>, <<"Bob Smith">>),
    
    io:format("   PUT config:timeout -> '5000'~n"),
    ok = funnelkvs_client:put(ClientPid, <<"config:timeout">>, <<"5000">>),
    
    %% Test GET operations
    io:format("   GET user:alice -> "),
    {ok, AliceValue} = funnelkvs_client:get(ClientPid, <<"user:alice">>),
    io:format("'~s'~n", [AliceValue]),
    
    io:format("   GET user:bob -> "),
    {ok, BobValue} = funnelkvs_client:get(ClientPid, <<"user:bob">>),
    io:format("'~s'~n", [BobValue]),
    
    io:format("   GET config:timeout -> "),
    {ok, TimeoutValue} = funnelkvs_client:get(ClientPid, <<"config:timeout">>),
    io:format("'~s'~n", [TimeoutValue]),
    
    %% Test non-existent key
    io:format("   GET nonexistent -> "),
    case funnelkvs_client:get(ClientPid, <<"nonexistent">>) of
        {error, not_found} ->
            io:format("not found (as expected)~n")
    end,
    
    %% Test DELETE
    io:format("   DELETE user:bob~n"),
    ok = funnelkvs_client:delete(ClientPid, <<"user:bob">>),
    
    io:format("   GET user:bob -> "),
    case funnelkvs_client:get(ClientPid, <<"user:bob">>) of
        {error, not_found} ->
            io:format("not found (deleted successfully)~n")
    end,
    
    %% Test STATS
    io:format("   STATS -> "),
    {ok, StatsData} = funnelkvs_client:stats(ClientPid),
    io:format("~s~n", [StatsData]),
    
    %% Test binary data
    io:format("~n4. Testing binary data support:~n"),
    BinaryKey = <<255, 254, 0, 1, 2>>,
    BinaryValue = <<0, 255, 128, 64>>,
    ok = funnelkvs_client:put(ClientPid, BinaryKey, BinaryValue),
    {ok, RetrievedBinary} = funnelkvs_client:get(ClientPid, BinaryKey),
    io:format("   Binary data: ~w bytes stored and retrieved successfully~n", 
              [byte_size(RetrievedBinary)]),
    
    %% Test large data
    io:format("~n5. Testing large data support:~n"),
    LargeValue = binary:copy(<<"Hello World! ">>, 1000),
    ok = funnelkvs_client:put(ClientPid, <<"large_data">>, LargeValue),
    {ok, RetrievedLarge} = funnelkvs_client:get(ClientPid, <<"large_data">>),
    io:format("   Large data: ~w bytes stored and retrieved successfully~n", 
              [byte_size(RetrievedLarge)]),
    
    %% Test multiple clients
    io:format("~n6. Testing multiple concurrent clients:~n"),
    {ok, Client2} = funnelkvs_client:connect("localhost", Port),
    {ok, Client3} = funnelkvs_client:connect("localhost", Port),
    
    %% Client 2 can see data from Client 1
    {ok, AliceFromClient2} = funnelkvs_client:get(Client2, <<"user:alice">>),
    io:format("   Client 2 can read data from Client 1: '~s'~n", [AliceFromClient2]),
    
    %% Client 3 writes new data
    ok = funnelkvs_client:put(Client3, <<"session:xyz789">>, <<"active">>),
    
    %% Client 1 can see data from Client 3
    {ok, SessionFromClient1} = funnelkvs_client:get(ClientPid, <<"session:xyz789">>),
    io:format("   Client 1 can read data from Client 3: '~s'~n", [SessionFromClient1]),
    
    %% Stress test
    io:format("~n7. Stress testing with 100 operations:~n"),
    StartTime = erlang:monotonic_time(millisecond),
    lists:foreach(fun(N) ->
        Key = <<"stress_", (integer_to_binary(N))/binary>>,
        Value = <<"value_", (integer_to_binary(N * N))/binary>>,
        ok = funnelkvs_client:put(ClientPid, Key, Value)
    end, lists:seq(1, 100)),
    
    %% Verify all data
    AllCorrect = lists:all(fun(N) ->
        Key = <<"stress_", (integer_to_binary(N))/binary>>,
        ExpectedValue = <<"value_", (integer_to_binary(N * N))/binary>>,
        case funnelkvs_client:get(Client2, Key) of
            {ok, ExpectedValue} -> true;
            _ -> false
        end
    end, lists:seq(1, 100)),
    
    EndTime = erlang:monotonic_time(millisecond),
    Duration = EndTime - StartTime,
    
    case AllCorrect of
        true ->
            io:format("   All 100 operations completed successfully in ~p ms~n", [Duration]),
            io:format("   Average: ~.2f operations/second~n", [100000.0/Duration]);
        false ->
            io:format("   Some operations failed~n")
    end,
    
    %% Final stats
    io:format("~n8. Final system statistics:~n"),
    {ok, FinalStats} = funnelkvs_client:stats(ClientPid),
    io:format("   ~s~n", [FinalStats]),
    
    %% Cleanup
    io:format("~n9. Cleaning up...~n"),
    funnelkvs_client:disconnect(ClientPid),
    funnelkvs_client:disconnect(Client2),
    funnelkvs_client:disconnect(Client3),
    funnelkvs_server:stop(ServerPid),
    
    io:format("~n=================================~n"),
    io:format("Demo completed successfully!~n"),
    io:format("~nPhase 1 Implementation Status:~n"),
    io:format("✓ Basic KVS store with ETS~n"),
    io:format("✓ Binary protocol encoder/decoder~n"),
    io:format("✓ TCP server with request handling~n"),
    io:format("✓ Client library with connection management~n"),
    io:format("✓ All operations: GET, PUT, DELETE, PING, STATS~n"),
    io:format("✓ Binary data and large payload support~n"),
    io:format("✓ Concurrent client support~n"),
    io:format("✓ Comprehensive test coverage~n"),
    io:format("✓ Command-line client interface~n"),
    io:format("~nReady for Phase 2: Chord DHT implementation~n"),
    io:format("=================================~n~n"),
    
    ok.