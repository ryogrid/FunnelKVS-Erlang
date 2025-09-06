-module(funnelkvs_protocol).

%% API
-export([encode_request/3, encode_response/2]).
-export([decode_request/1, decode_response/1]).

%% Protocol constants
-define(MAGIC, <<16#4B, 16#56, 16#53>>).  % "KVS"
-define(VERSION, 16#01).

%% Operation codes
-define(OP_GET, 16#01).
-define(OP_PUT, 16#02).
-define(OP_DELETE, 16#03).
-define(OP_PING, 16#04).
-define(OP_STATS, 16#05).

%% Status codes
-define(STATUS_SUCCESS, 16#00).
-define(STATUS_NOT_FOUND, 16#01).
-define(STATUS_INVALID_REQUEST, 16#02).
-define(STATUS_SERVER_ERROR, 16#03).
-define(STATUS_TIMEOUT, 16#04).
-define(STATUS_NOT_RESPONSIBLE, 16#05).

%%%===================================================================
%%% API - Encoding
%%%===================================================================

encode_request(get, Key, _Value) when is_binary(Key) ->
    KeyLen = byte_size(Key),
    <<?MAGIC/binary, ?VERSION, ?OP_GET, KeyLen:32/big, Key/binary>>;

encode_request(put, Key, Value) when is_binary(Key), is_binary(Value) ->
    KeyLen = byte_size(Key),
    ValueLen = byte_size(Value),
    <<?MAGIC/binary, ?VERSION, ?OP_PUT, KeyLen:32/big, Key/binary, 
      ValueLen:32/big, Value/binary>>;

encode_request(delete, Key, _Value) when is_binary(Key) ->
    KeyLen = byte_size(Key),
    <<?MAGIC/binary, ?VERSION, ?OP_DELETE, KeyLen:32/big, Key/binary>>;

encode_request(ping, _Key, _Value) ->
    <<?MAGIC/binary, ?VERSION, ?OP_PING>>;

encode_request(stats, _Key, _Value) ->
    <<?MAGIC/binary, ?VERSION, ?OP_STATS>>.

encode_response(success, Value) when is_binary(Value) ->
    ValueLen = byte_size(Value),
    <<?MAGIC/binary, ?VERSION, ?STATUS_SUCCESS, ValueLen:32/big, Value/binary>>;

encode_response(success, undefined) ->
    <<?MAGIC/binary, ?VERSION, ?STATUS_SUCCESS, 0:32/big>>;

encode_response(not_found, _Value) ->
    <<?MAGIC/binary, ?VERSION, ?STATUS_NOT_FOUND, 0:32/big>>;

encode_response(invalid_request, _Value) ->
    <<?MAGIC/binary, ?VERSION, ?STATUS_INVALID_REQUEST, 0:32/big>>;

encode_response(server_error, _Value) ->
    <<?MAGIC/binary, ?VERSION, ?STATUS_SERVER_ERROR, 0:32/big>>;

encode_response(timeout, _Value) ->
    <<?MAGIC/binary, ?VERSION, ?STATUS_TIMEOUT, 0:32/big>>;

encode_response(not_responsible, _Value) ->
    <<?MAGIC/binary, ?VERSION, ?STATUS_NOT_RESPONSIBLE, 0:32/big>>.

%%%===================================================================
%%% API - Decoding
%%%===================================================================

decode_request(<<16#4B, 16#56, 16#53, ?VERSION, OpCode, Rest/binary>>) ->
    case OpCode of
        ?OP_GET ->
            decode_get_request(Rest);
        ?OP_PUT ->
            decode_put_request(Rest);
        ?OP_DELETE ->
            decode_delete_request(Rest);
        ?OP_PING ->
            {ok, {ping, undefined, undefined}};
        ?OP_STATS ->
            {ok, {stats, undefined, undefined}};
        _ ->
            {error, invalid_operation}
    end;

decode_request(<<16#4B, 16#56, 16#53, Version, _Rest/binary>>) when Version =/= ?VERSION ->
    {error, unsupported_version};

decode_request(<<Magic:3/binary, _Rest/binary>>) when Magic =/= ?MAGIC ->
    {error, invalid_magic};

decode_request(_) ->
    {error, truncated_message}.

decode_response(<<16#4B, 16#56, 16#53, ?VERSION, Status, ValueLen:32/big, Rest/binary>>) ->
    case byte_size(Rest) of
        ValueLen ->
            Value = Rest,
            StatusAtom = decode_status(Status),
            {ok, {StatusAtom, Value}};
        _ ->
            {error, truncated_message}
    end;

decode_response(<<16#4B, 16#56, 16#53, Version, _Rest/binary>>) when Version =/= ?VERSION ->
    {error, unsupported_version};

decode_response(<<Magic:3/binary, _Rest/binary>>) when Magic =/= ?MAGIC ->
    {error, invalid_magic};

decode_response(_) ->
    {error, truncated_message}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

decode_get_request(<<KeyLen:32/big, Rest/binary>>) ->
    case byte_size(Rest) of
        KeyLen ->
            Key = Rest,
            {ok, {get, Key, undefined}};
        _ ->
            {error, truncated_message}
    end;
decode_get_request(_) ->
    {error, truncated_message}.

decode_put_request(<<KeyLen:32/big, Rest/binary>>) ->
    case Rest of
        <<Key:KeyLen/binary, ValueLen:32/big, Value/binary>> when byte_size(Value) =:= ValueLen ->
            {ok, {put, Key, Value}};
        _ ->
            {error, truncated_message}
    end;
decode_put_request(_) ->
    {error, truncated_message}.

decode_delete_request(<<KeyLen:32/big, Rest/binary>>) ->
    case byte_size(Rest) of
        KeyLen ->
            Key = Rest,
            {ok, {delete, Key, undefined}};
        _ ->
            {error, truncated_message}
    end;
decode_delete_request(_) ->
    {error, truncated_message}.

decode_status(?STATUS_SUCCESS) -> success;
decode_status(?STATUS_NOT_FOUND) -> not_found;
decode_status(?STATUS_INVALID_REQUEST) -> invalid_request;
decode_status(?STATUS_SERVER_ERROR) -> server_error;
decode_status(?STATUS_TIMEOUT) -> timeout;
decode_status(?STATUS_NOT_RESPONSIBLE) -> not_responsible;
decode_status(_) -> unknown_status.