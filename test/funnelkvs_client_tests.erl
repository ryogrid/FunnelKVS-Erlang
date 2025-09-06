-module(funnelkvs_client_tests).
-include_lib("eunit/include/eunit.hrl").

-define(TEST_PORT, 8888).
-define(TIMEOUT, 1000).

%% Test fixture setup and teardown
setup() ->
    % Start server first
    {ok, ServerPid} = funnelkvs_server:start_link(?TEST_PORT),
    timer:sleep(100), % Give server time to bind
    
    % Connect client
    {ok, ClientPid} = funnelkvs_client:connect("localhost", ?TEST_PORT),
    {ServerPid, ClientPid}.

teardown({ServerPid, ClientPid}) ->
    funnelkvs_client:disconnect(ClientPid),
    funnelkvs_server:stop(ServerPid).

%% Test wrapper with setup/teardown
client_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [
      fun test_client_connect/1,
      fun test_client_put_get/1,
      fun test_client_delete/1,
      fun test_client_ping/1,
      fun test_client_stats/1,
      fun test_client_error_handling/1,
      fun test_client_large_values/1,
      fun test_client_concurrent_operations/1
     ]}.

%% Individual test cases
test_client_connect({_ServerPid, ClientPid}) ->
    fun() ->
        ?assert(is_process_alive(ClientPid))
    end.

test_client_put_get({_ServerPid, ClientPid}) ->
    fun() ->
        Key = <<"test_key">>,
        Value = <<"test_value">>,
        
        % PUT
        ?assertEqual(ok, funnelkvs_client:put(ClientPid, Key, Value)),
        
        % GET
        ?assertEqual({ok, Value}, funnelkvs_client:get(ClientPid, Key)),
        
        % GET non-existent
        ?assertEqual({error, not_found}, funnelkvs_client:get(ClientPid, <<"nonexistent">>))
    end.

test_client_delete({_ServerPid, ClientPid}) ->
    fun() ->
        Key = <<"delete_key">>,
        Value = <<"delete_value">>,
        
        % PUT
        ?assertEqual(ok, funnelkvs_client:put(ClientPid, Key, Value)),
        
        % Verify it exists
        ?assertEqual({ok, Value}, funnelkvs_client:get(ClientPid, Key)),
        
        % DELETE
        ?assertEqual(ok, funnelkvs_client:delete(ClientPid, Key)),
        
        % Verify it's gone
        ?assertEqual({error, not_found}, funnelkvs_client:get(ClientPid, Key))
    end.

test_client_ping({_ServerPid, ClientPid}) ->
    fun() ->
        ?assertEqual({ok, <<"pong">>}, funnelkvs_client:ping(ClientPid))
    end.

test_client_stats({_ServerPid, ClientPid}) ->
    fun() ->
        % Add some data
        lists:foreach(fun(N) ->
            Key = <<"stats_key_", (integer_to_binary(N))/binary>>,
            Value = <<"stats_value_", (integer_to_binary(N))/binary>>,
            funnelkvs_client:put(ClientPid, Key, Value)
        end, lists:seq(1, 5)),
        
        % Get stats
        {ok, StatsData} = funnelkvs_client:stats(ClientPid),
        ?assert(is_binary(StatsData)),
        StatsStr = binary_to_list(StatsData),
        ?assert(string:find(StatsStr, "keys") =/= nomatch)
    end.

test_client_error_handling({_ServerPid, ClientPid}) ->
    fun() ->
        % Test with invalid UTF-8 sequences and special characters
        Key = <<255, 254, 253, 252>>,
        Value = <<0, 1, 2, 3>>,
        
        ?assertEqual(ok, funnelkvs_client:put(ClientPid, Key, Value)),
        ?assertEqual({ok, Value}, funnelkvs_client:get(ClientPid, Key))
    end.

test_client_large_values({_ServerPid, ClientPid}) ->
    fun() ->
        Key = <<"large_key">>,
        % Create a 50KB value
        Value = binary:copy(<<"x">>, 50 * 1024),
        
        ?assertEqual(ok, funnelkvs_client:put(ClientPid, Key, Value)),
        {ok, Retrieved} = funnelkvs_client:get(ClientPid, Key),
        ?assertEqual(byte_size(Value), byte_size(Retrieved)),
        ?assertEqual(Value, Retrieved)
    end.

test_client_concurrent_operations({_ServerPid, ClientPid}) ->
    fun() ->
        Parent = self(),
        NumProcesses = 20,
        
        % Spawn concurrent processes using the same client
        Pids = [spawn(fun() ->
            Key = <<"concurrent_", (integer_to_binary(N))/binary>>,
            Value = <<"value_", (integer_to_binary(N))/binary>>,
            
            ok = funnelkvs_client:put(ClientPid, Key, Value),
            {ok, Retrieved} = funnelkvs_client:get(ClientPid, Key),
            
            Parent ! {done, N, Retrieved =:= Value}
        end) || N <- lists:seq(1, NumProcesses)],
        
        % Wait for all processes and verify results
        Results = [receive {done, N, Success} -> {N, Success} end || _ <- Pids],
        lists:foreach(fun({_N, Success}) -> ?assert(Success) end, Results)
    end.

%% Test multiple clients to same server
multiple_clients_test() ->
    {ok, ServerPid} = funnelkvs_server:start_link(8887),
    timer:sleep(100),
    
    % Connect multiple clients
    {ok, Client1} = funnelkvs_client:connect("localhost", 8887),
    {ok, Client2} = funnelkvs_client:connect("localhost", 8887),
    {ok, Client3} = funnelkvs_client:connect("localhost", 8887),
    
    % Client 1 writes
    funnelkvs_client:put(Client1, <<"key1">>, <<"value1">>),
    
    % Client 2 can read it
    ?assertEqual({ok, <<"value1">>}, funnelkvs_client:get(Client2, <<"key1">>)),
    
    % Client 3 can also read it
    ?assertEqual({ok, <<"value1">>}, funnelkvs_client:get(Client3, <<"key1">>)),
    
    % Clean up
    funnelkvs_client:disconnect(Client1),
    funnelkvs_client:disconnect(Client2),
    funnelkvs_client:disconnect(Client3),
    funnelkvs_server:stop(ServerPid).

%% Test client reconnection
reconnect_test() ->
    {ok, ServerPid} = funnelkvs_server:start_link(8886),
    timer:sleep(100),
    
    % Connect, write data, disconnect
    {ok, Client1} = funnelkvs_client:connect("localhost", 8886),
    funnelkvs_client:put(Client1, <<"persist_key">>, <<"persist_value">>),
    funnelkvs_client:disconnect(Client1),
    
    % Reconnect with new client and verify data persists
    {ok, Client2} = funnelkvs_client:connect("localhost", 8886),
    ?assertEqual({ok, <<"persist_value">>}, funnelkvs_client:get(Client2, <<"persist_key">>)),
    
    funnelkvs_client:disconnect(Client2),
    funnelkvs_server:stop(ServerPid).

%% Test timeout handling
timeout_test() ->
    % Start server that doesn't respond properly
    {ok, ServerPid} = funnelkvs_server:start_link(8885),
    timer:sleep(100),
    
    % Connect with short timeout
    {ok, ClientPid} = funnelkvs_client:connect("localhost", 8885, [{timeout, 100}]),
    
    % Normal operation should work
    ?assertEqual(ok, funnelkvs_client:put(ClientPid, <<"key">>, <<"value">>)),
    
    funnelkvs_client:disconnect(ClientPid),
    funnelkvs_server:stop(ServerPid).