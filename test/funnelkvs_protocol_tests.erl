-module(funnelkvs_protocol_tests).
-include_lib("eunit/include/eunit.hrl").

%% Test encoding and decoding of protocol messages

%% Request encoding tests
encode_get_request_test() ->
    Key = <<"mykey">>,
    Expected = <<16#4B, 16#56, 16#53, 16#01,  % Magic bytes "KVS" + version 1
                 16#01,                         % GET operation
                 5:32/big,                      % Key length
                 "mykey">>,                     % Key
    Result = funnelkvs_protocol:encode_request(get, Key, undefined),
    ?assertEqual(Expected, Result).

encode_put_request_test() ->
    Key = <<"key1">>,
    Value = <<"value1">>,
    Expected = <<16#4B, 16#56, 16#53, 16#01,  % Magic bytes "KVS" + version 1
                 16#02,                         % PUT operation
                 4:32/big,                      % Key length
                 "key1",                        % Key
                 6:32/big,                      % Value length
                 "value1">>,                    % Value
    Result = funnelkvs_protocol:encode_request(put, Key, Value),
    ?assertEqual(Expected, Result).

encode_delete_request_test() ->
    Key = <<"delkey">>,
    Expected = <<16#4B, 16#56, 16#53, 16#01,  % Magic bytes "KVS" + version 1
                 16#03,                         % DELETE operation
                 6:32/big,                      % Key length
                 "delkey">>,                    % Key
    Result = funnelkvs_protocol:encode_request(delete, Key, undefined),
    ?assertEqual(Expected, Result).

encode_ping_request_test() ->
    Expected = <<16#4B, 16#56, 16#53, 16#01,  % Magic bytes "KVS" + version 1
                 16#04>>,                       % PING operation
    Result = funnelkvs_protocol:encode_request(ping, undefined, undefined),
    ?assertEqual(Expected, Result).

encode_stats_request_test() ->
    Expected = <<16#4B, 16#56, 16#53, 16#01,  % Magic bytes "KVS" + version 1
                 16#05>>,                       % STATS operation
    Result = funnelkvs_protocol:encode_request(stats, undefined, undefined),
    ?assertEqual(Expected, Result).

%% Response encoding tests
encode_success_response_test() ->
    Value = <<"result">>,
    Expected = <<16#4B, 16#56, 16#53, 16#01,  % Magic bytes "KVS" + version 1
                 16#00,                         % SUCCESS status
                 6:32/big,                      % Value length
                 "result">>,                    % Value
    Result = funnelkvs_protocol:encode_response(success, Value),
    ?assertEqual(Expected, Result).

encode_not_found_response_test() ->
    Expected = <<16#4B, 16#56, 16#53, 16#01,  % Magic bytes "KVS" + version 1
                 16#01,                         % KEY_NOT_FOUND status
                 0:32/big>>,                    % No value
    Result = funnelkvs_protocol:encode_response(not_found, undefined),
    ?assertEqual(Expected, Result).

encode_error_response_test() ->
    Expected = <<16#4B, 16#56, 16#53, 16#01,  % Magic bytes "KVS" + version 1
                 16#03,                         % SERVER_ERROR status
                 0:32/big>>,                    % No value
    Result = funnelkvs_protocol:encode_response(server_error, undefined),
    ?assertEqual(Expected, Result).

%% Request decoding tests
decode_get_request_test() ->
    Binary = <<16#4B, 16#56, 16#53, 16#01,    % Magic bytes "KVS" + version 1
               16#01,                           % GET operation
               5:32/big,                        % Key length
               "mykey">>,                       % Key
    Expected = {ok, {get, <<"mykey">>, undefined}},
    Result = funnelkvs_protocol:decode_request(Binary),
    ?assertEqual(Expected, Result).

decode_put_request_test() ->
    Binary = <<16#4B, 16#56, 16#53, 16#01,    % Magic bytes "KVS" + version 1
               16#02,                           % PUT operation
               4:32/big,                        % Key length
               "key1",                          % Key
               6:32/big,                        % Value length
               "value1">>,                      % Value
    Expected = {ok, {put, <<"key1">>, <<"value1">>}},
    Result = funnelkvs_protocol:decode_request(Binary),
    ?assertEqual(Expected, Result).

decode_delete_request_test() ->
    Binary = <<16#4B, 16#56, 16#53, 16#01,    % Magic bytes "KVS" + version 1
               16#03,                           % DELETE operation
               6:32/big,                        % Key length
               "delkey">>,                      % Key
    Expected = {ok, {delete, <<"delkey">>, undefined}},
    Result = funnelkvs_protocol:decode_request(Binary),
    ?assertEqual(Expected, Result).

decode_ping_request_test() ->
    Binary = <<16#4B, 16#56, 16#53, 16#01,    % Magic bytes "KVS" + version 1
               16#04>>,                         % PING operation
    Expected = {ok, {ping, undefined, undefined}},
    Result = funnelkvs_protocol:decode_request(Binary),
    ?assertEqual(Expected, Result).

decode_stats_request_test() ->
    Binary = <<16#4B, 16#56, 16#53, 16#01,    % Magic bytes "KVS" + version 1
               16#05>>,                         % STATS operation
    Expected = {ok, {stats, undefined, undefined}},
    Result = funnelkvs_protocol:decode_request(Binary),
    ?assertEqual(Expected, Result).

%% Response decoding tests
decode_success_response_test() ->
    Binary = <<16#4B, 16#56, 16#53, 16#01,    % Magic bytes "KVS" + version 1
               16#00,                           % SUCCESS status
               6:32/big,                        % Value length
               "result">>,                      % Value
    Expected = {ok, {success, <<"result">>}},
    Result = funnelkvs_protocol:decode_response(Binary),
    ?assertEqual(Expected, Result).

decode_not_found_response_test() ->
    Binary = <<16#4B, 16#56, 16#53, 16#01,    % Magic bytes "KVS" + version 1
               16#01,                           % KEY_NOT_FOUND status
               0:32/big>>,                      % No value
    Expected = {ok, {not_found, <<>>}},
    Result = funnelkvs_protocol:decode_response(Binary),
    ?assertEqual(Expected, Result).

decode_error_response_test() ->
    Binary = <<16#4B, 16#56, 16#53, 16#01,    % Magic bytes "KVS" + version 1
               16#03,                           % SERVER_ERROR status
               0:32/big>>,                      % No value
    Expected = {ok, {server_error, <<>>}},
    Result = funnelkvs_protocol:decode_response(Binary),
    ?assertEqual(Expected, Result).

%% Error handling tests
decode_invalid_magic_test() ->
    Binary = <<16#FF, 16#FF, 16#FF, 16#01,    % Invalid magic bytes
               16#01,                           % GET operation
               5:32/big,                        % Key length
               "mykey">>,                       % Key
    Result = funnelkvs_protocol:decode_request(Binary),
    ?assertMatch({error, invalid_magic}, Result).

decode_invalid_version_test() ->
    Binary = <<16#4B, 16#56, 16#53, 16#FF,    % Valid magic, invalid version
               16#01,                           % GET operation
               5:32/big,                        % Key length
               "mykey">>,                       % Key
    Result = funnelkvs_protocol:decode_request(Binary),
    ?assertMatch({error, unsupported_version}, Result).

decode_invalid_operation_test() ->
    Binary = <<16#4B, 16#56, 16#53, 16#01,    % Magic bytes "KVS" + version 1
               16#FF,                           % Invalid operation
               5:32/big,                        % Key length
               "mykey">>,                       % Key
    Result = funnelkvs_protocol:decode_request(Binary),
    ?assertMatch({error, invalid_operation}, Result).

decode_truncated_request_test() ->
    Binary = <<16#4B, 16#56, 16#53, 16#01,    % Magic bytes "KVS" + version 1
               16#01,                           % GET operation
               5:32/big,                        % Key length
               "my">>,                          % Truncated key
    Result = funnelkvs_protocol:decode_request(Binary),
    ?assertMatch({error, truncated_message}, Result).

%% Round-trip tests
round_trip_get_test() ->
    Key = <<"test_key">>,
    Encoded = funnelkvs_protocol:encode_request(get, Key, undefined),
    {ok, Decoded} = funnelkvs_protocol:decode_request(Encoded),
    ?assertEqual({get, Key, undefined}, Decoded).

round_trip_put_test() ->
    Key = <<"test_key">>,
    Value = <<"test_value">>,
    Encoded = funnelkvs_protocol:encode_request(put, Key, Value),
    {ok, Decoded} = funnelkvs_protocol:decode_request(Encoded),
    ?assertEqual({put, Key, Value}, Decoded).

round_trip_response_test() ->
    Value = <<"response_value">>,
    Encoded = funnelkvs_protocol:encode_response(success, Value),
    {ok, Decoded} = funnelkvs_protocol:decode_response(Encoded),
    ?assertEqual({success, Value}, Decoded).

%% Edge cases
empty_key_test() ->
    Key = <<>>,
    Value = <<"value">>,
    Encoded = funnelkvs_protocol:encode_request(put, Key, Value),
    {ok, Decoded} = funnelkvs_protocol:decode_request(Encoded),
    ?assertEqual({put, Key, Value}, Decoded).

empty_value_test() ->
    Key = <<"key">>,
    Value = <<>>,
    Encoded = funnelkvs_protocol:encode_request(put, Key, Value),
    {ok, Decoded} = funnelkvs_protocol:decode_request(Encoded),
    ?assertEqual({put, Key, Value}, Decoded).

large_key_value_test() ->
    Key = binary:copy(<<"k">>, 10000),
    Value = binary:copy(<<"v">>, 100000),
    Encoded = funnelkvs_protocol:encode_request(put, Key, Value),
    {ok, Decoded} = funnelkvs_protocol:decode_request(Encoded),
    ?assertEqual({put, Key, Value}, Decoded).

binary_data_test() ->
    Key = <<0, 1, 2, 3, 255, 254, 253, 252>>,
    Value = <<255, 254, 253, 252, 0, 1, 2, 3>>,
    Encoded = funnelkvs_protocol:encode_request(put, Key, Value),
    {ok, Decoded} = funnelkvs_protocol:decode_request(Encoded),
    ?assertEqual({put, Key, Value}, Decoded).