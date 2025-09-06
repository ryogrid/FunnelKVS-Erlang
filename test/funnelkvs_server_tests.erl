-module(funnelkvs_server_tests).
-include_lib("eunit/include/eunit.hrl").

-define(TEST_PORT, 9999).
-define(TIMEOUT, 1000).

%% Test fixture setup and teardown
setup() ->
    {ok, Pid} = funnelkvs_server:start_link(?TEST_PORT),
    timer:sleep(100), % Give server time to bind
    Pid.

teardown(Pid) ->
    funnelkvs_server:stop(Pid).

%% Test wrapper with setup/teardown
server_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [
      fun test_server_starts/1,
      fun test_ping_request/1,
      fun test_get_nonexistent/1,
      fun test_put_and_get/1,
      fun test_delete/1,
      fun test_multiple_clients/1,
      fun test_invalid_request/1,
      fun test_large_payload/1
     ]}.

%% Individual test cases
test_server_starts(_Pid) ->
    fun() ->
        % Try to connect to the server
        case gen_tcp:connect("localhost", ?TEST_PORT, [binary, {packet, 0}, {active, false}]) of
            {ok, Socket} ->
                gen_tcp:close(Socket),
                ?assert(true);
            {error, _Reason} ->
                ?assert(false)
        end
    end.

test_ping_request(_Pid) ->
    fun() ->
        {ok, Socket} = gen_tcp:connect("localhost", ?TEST_PORT, [binary, {packet, 0}, {active, false}]),
        
        % Send PING request
        Request = funnelkvs_protocol:encode_request(ping, undefined, undefined),
        ok = gen_tcp:send(Socket, Request),
        
        % Receive response
        {ok, Response} = gen_tcp:recv(Socket, 0, ?TIMEOUT),
        {ok, {success, _}} = funnelkvs_protocol:decode_response(Response),
        
        gen_tcp:close(Socket)
    end.

test_get_nonexistent(_Pid) ->
    fun() ->
        {ok, Socket} = gen_tcp:connect("localhost", ?TEST_PORT, [binary, {packet, 0}, {active, false}]),
        
        % Send GET request for non-existent key
        Request = funnelkvs_protocol:encode_request(get, <<"nonexistent">>, undefined),
        ok = gen_tcp:send(Socket, Request),
        
        % Receive response
        {ok, Response} = gen_tcp:recv(Socket, 0, ?TIMEOUT),
        {ok, {not_found, _}} = funnelkvs_protocol:decode_response(Response),
        
        gen_tcp:close(Socket)
    end.

test_put_and_get(_Pid) ->
    fun() ->
        {ok, Socket} = gen_tcp:connect("localhost", ?TEST_PORT, [binary, {packet, 0}, {active, false}]),
        
        Key = <<"test_key">>,
        Value = <<"test_value">>,
        
        % Send PUT request
        PutRequest = funnelkvs_protocol:encode_request(put, Key, Value),
        ok = gen_tcp:send(Socket, PutRequest),
        
        % Receive PUT response
        {ok, PutResponse} = gen_tcp:recv(Socket, 0, ?TIMEOUT),
        {ok, {success, _}} = funnelkvs_protocol:decode_response(PutResponse),
        
        % Send GET request
        GetRequest = funnelkvs_protocol:encode_request(get, Key, undefined),
        ok = gen_tcp:send(Socket, GetRequest),
        
        % Receive GET response
        {ok, GetResponse} = gen_tcp:recv(Socket, 0, ?TIMEOUT),
        {ok, {success, ReturnedValue}} = funnelkvs_protocol:decode_response(GetResponse),
        ?assertEqual(Value, ReturnedValue),
        
        gen_tcp:close(Socket)
    end.

test_delete(_Pid) ->
    fun() ->
        {ok, Socket} = gen_tcp:connect("localhost", ?TEST_PORT, [binary, {packet, 0}, {active, false}]),
        
        Key = <<"delete_key">>,
        Value = <<"delete_value">>,
        
        % First PUT the key
        PutRequest = funnelkvs_protocol:encode_request(put, Key, Value),
        ok = gen_tcp:send(Socket, PutRequest),
        {ok, _} = gen_tcp:recv(Socket, 0, ?TIMEOUT),
        
        % DELETE the key
        DeleteRequest = funnelkvs_protocol:encode_request(delete, Key, undefined),
        ok = gen_tcp:send(Socket, DeleteRequest),
        {ok, DeleteResponse} = gen_tcp:recv(Socket, 0, ?TIMEOUT),
        {ok, {success, _}} = funnelkvs_protocol:decode_response(DeleteResponse),
        
        % Try to GET the deleted key
        GetRequest = funnelkvs_protocol:encode_request(get, Key, undefined),
        ok = gen_tcp:send(Socket, GetRequest),
        {ok, GetResponse} = gen_tcp:recv(Socket, 0, ?TIMEOUT),
        {ok, {not_found, _}} = funnelkvs_protocol:decode_response(GetResponse),
        
        gen_tcp:close(Socket)
    end.

test_multiple_clients(_Pid) ->
    fun() ->
        NumClients = 10,
        Parent = self(),
        
        % Spawn multiple clients
        Pids = [spawn(fun() ->
            {ok, Socket} = gen_tcp:connect("localhost", ?TEST_PORT, [binary, {packet, 0}, {active, false}]),
            
            Key = <<"client_", (integer_to_binary(N))/binary>>,
            Value = <<"value_", (integer_to_binary(N))/binary>>,
            
            % PUT
            PutRequest = funnelkvs_protocol:encode_request(put, Key, Value),
            ok = gen_tcp:send(Socket, PutRequest),
            {ok, _} = gen_tcp:recv(Socket, 0, ?TIMEOUT),
            
            % GET
            GetRequest = funnelkvs_protocol:encode_request(get, Key, undefined),
            ok = gen_tcp:send(Socket, GetRequest),
            {ok, GetResponse} = gen_tcp:recv(Socket, 0, ?TIMEOUT),
            {ok, {success, RetValue}} = funnelkvs_protocol:decode_response(GetResponse),
            
            gen_tcp:close(Socket),
            Parent ! {done, N, RetValue =:= Value}
        end) || N <- lists:seq(1, NumClients)],
        
        % Wait for all clients and verify results
        Results = [receive {done, N, Success} -> {N, Success} end || _ <- Pids],
        lists:foreach(fun({_N, Success}) -> ?assert(Success) end, Results)
    end.

test_invalid_request(_Pid) ->
    fun() ->
        {ok, Socket} = gen_tcp:connect("localhost", ?TEST_PORT, [binary, {packet, 0}, {active, false}]),
        
        % Send invalid request (bad magic bytes)
        InvalidRequest = <<16#FF, 16#FF, 16#FF, 16#01, 16#01>>,
        ok = gen_tcp:send(Socket, InvalidRequest),
        
        % Should receive error response
        {ok, Response} = gen_tcp:recv(Socket, 0, ?TIMEOUT),
        {ok, {invalid_request, _}} = funnelkvs_protocol:decode_response(Response),
        
        gen_tcp:close(Socket)
    end.

test_large_payload(_Pid) ->
    fun() ->
        {ok, Socket} = gen_tcp:connect("localhost", ?TEST_PORT, [binary, {packet, 0}, {active, false}]),
        
        Key = <<"large_key">>,
        % Create a 100KB value
        Value = binary:copy(<<"x">>, 100 * 1024),
        
        % Send PUT request
        PutRequest = funnelkvs_protocol:encode_request(put, Key, Value),
        ok = gen_tcp:send(Socket, PutRequest),
        
        % Receive PUT response
        {ok, PutResponse} = receive_complete_response(Socket, ?TIMEOUT * 10),
        {ok, {success, _}} = funnelkvs_protocol:decode_response(PutResponse),
        
        % Send GET request
        GetRequest = funnelkvs_protocol:encode_request(get, Key, undefined),
        ok = gen_tcp:send(Socket, GetRequest),
        
        % Receive GET response (accumulate data until we have a complete response)
        {ok, GetResponse} = receive_complete_response(Socket, ?TIMEOUT * 10),
        {ok, {success, ReturnedValue}} = funnelkvs_protocol:decode_response(GetResponse),
        ?assertEqual(byte_size(Value), byte_size(ReturnedValue)),
        ?assertEqual(Value, ReturnedValue),
        
        gen_tcp:close(Socket)
    end.

%% Helper function to receive complete response
receive_complete_response(Socket, Timeout) ->
    receive_complete_response(Socket, Timeout, <<>>).

receive_complete_response(Socket, Timeout, Buffer) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} ->
            NewBuffer = <<Buffer/binary, Data/binary>>,
            % Try to decode the response to see if it's complete
            case try_decode_response(NewBuffer) of
                {ok, complete} ->
                    {ok, NewBuffer};
                {need_more_data} ->
                    receive_complete_response(Socket, Timeout, NewBuffer);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

try_decode_response(Buffer) when byte_size(Buffer) < 9 ->
    {need_more_data};
try_decode_response(<<16#4B, 16#56, 16#53, 16#01, _Status, ValueLen:32/big, Rest/binary>>) ->
    if byte_size(Rest) >= ValueLen ->
        {ok, complete};
    true ->
        {need_more_data}
    end;
try_decode_response(_) ->
    {error, invalid_response}.

%% Test STATS request
stats_request_test() ->
    {ok, Pid} = funnelkvs_server:start_link(9998),
    timer:sleep(100),
    
    {ok, Socket} = gen_tcp:connect("localhost", 9998, [binary, {packet, 0}, {active, false}]),
    
    % Add some data first
    lists:foreach(fun(N) ->
        Key = <<"stats_key_", (integer_to_binary(N))/binary>>,
        Value = <<"stats_value_", (integer_to_binary(N))/binary>>,
        Request = funnelkvs_protocol:encode_request(put, Key, Value),
        ok = gen_tcp:send(Socket, Request),
        {ok, _} = gen_tcp:recv(Socket, 0, ?TIMEOUT)
    end, lists:seq(1, 5)),
    
    % Send STATS request
    StatsRequest = funnelkvs_protocol:encode_request(stats, undefined, undefined),
    ok = gen_tcp:send(Socket, StatsRequest),
    
    % Receive response
    {ok, Response} = gen_tcp:recv(Socket, 0, ?TIMEOUT),
    {ok, {success, StatsData}} = funnelkvs_protocol:decode_response(Response),
    
    % Verify stats contain expected information
    ?assert(is_binary(StatsData)),
    StatsStr = binary_to_list(StatsData),
    ?assert(string:find(StatsStr, "keys") =/= nomatch),
    
    gen_tcp:close(Socket),
    funnelkvs_server:stop(Pid).

%% Test persistent connection
persistent_connection_test() ->
    {ok, Pid} = funnelkvs_server:start_link(9997),
    timer:sleep(100),
    
    {ok, Socket} = gen_tcp:connect("localhost", 9997, [binary, {packet, 0}, {active, false}]),
    
    % Send multiple requests on the same connection
    lists:foreach(fun(N) ->
        Key = <<"persist_", (integer_to_binary(N))/binary>>,
        Value = <<"value_", (integer_to_binary(N))/binary>>,
        
        % PUT
        PutReq = funnelkvs_protocol:encode_request(put, Key, Value),
        ok = gen_tcp:send(Socket, PutReq),
        {ok, PutResp} = gen_tcp:recv(Socket, 0, ?TIMEOUT),
        {ok, {success, _}} = funnelkvs_protocol:decode_response(PutResp),
        
        % GET
        GetReq = funnelkvs_protocol:encode_request(get, Key, undefined),
        ok = gen_tcp:send(Socket, GetReq),
        {ok, GetResp} = gen_tcp:recv(Socket, 0, ?TIMEOUT),
        {ok, {success, RetVal}} = funnelkvs_protocol:decode_response(GetResp),
        ?assertEqual(Value, RetVal)
    end, lists:seq(1, 10)),
    
    gen_tcp:close(Socket),
    funnelkvs_server:stop(Pid).