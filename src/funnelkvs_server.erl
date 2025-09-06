-module(funnelkvs_server).
-behaviour(gen_server).

%% API
-export([start_link/1, stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    port :: inet:port_number(),
    listen_socket :: gen_tcp:socket(),
    kvs_store :: pid(),
    acceptor :: pid()
}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Port) ->
    gen_server:start_link(?MODULE, [Port], []).

stop(Pid) ->
    gen_server:stop(Pid).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Port]) ->
    process_flag(trap_exit, true),
    
    % Start the KVS store
    {ok, KvsStore} = kvs_store:start_link(),
    
    % Open listening socket
    case gen_tcp:listen(Port, [binary, {packet, 0}, {active, false}, 
                               {reuseaddr, true}, {backlog, 100}]) of
        {ok, ListenSocket} ->
            % Start acceptor process
            Acceptor = spawn_link(fun() -> accept_loop(ListenSocket, KvsStore) end),
            {ok, #state{port = Port, 
                       listen_socket = ListenSocket,
                       kvs_store = KvsStore,
                       acceptor = Acceptor}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, _Reason}, #state{acceptor = Pid} = State) ->
    % Restart acceptor if it crashes
    NewAcceptor = spawn_link(fun() -> 
        accept_loop(State#state.listen_socket, State#state.kvs_store) 
    end),
    {noreply, State#state{acceptor = NewAcceptor}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{listen_socket = ListenSocket, kvs_store = KvsStore}) ->
    gen_tcp:close(ListenSocket),
    kvs_store:stop(KvsStore),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

accept_loop(ListenSocket, KvsStore) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            % Spawn a new process to handle this client
            spawn(fun() -> handle_client(Socket, KvsStore) end),
            accept_loop(ListenSocket, KvsStore);
        {error, closed} ->
            ok;
        {error, _Reason} ->
            timer:sleep(100),
            accept_loop(ListenSocket, KvsStore)
    end.

handle_client(Socket, KvsStore) ->
    handle_client(Socket, KvsStore, <<>>).

handle_client(Socket, KvsStore, Buffer) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            NewBuffer = <<Buffer/binary, Data/binary>>,
            process_buffer(Socket, KvsStore, NewBuffer);
        {error, closed} ->
            ok;
        {error, _Reason} ->
            gen_tcp:close(Socket)
    end.

process_buffer(Socket, KvsStore, Buffer) ->
    case try_decode_request(Buffer) of
        {ok, Request, Rest} ->
            Response = process_request_decoded(Request, KvsStore),
            gen_tcp:send(Socket, Response),
            % Continue processing if there's more data
            if byte_size(Rest) > 0 ->
                process_buffer(Socket, KvsStore, Rest);
            true ->
                handle_client(Socket, KvsStore, Rest)
            end;
        {need_more_data, _} ->
            % Wait for more data
            handle_client(Socket, KvsStore, Buffer);
        {error, _} ->
            % Send error response and continue
            Response = funnelkvs_protocol:encode_response(invalid_request, undefined),
            gen_tcp:send(Socket, Response),
            handle_client(Socket, KvsStore, <<>>)
    end.

try_decode_request(Buffer) when byte_size(Buffer) < 5 ->
    {need_more_data, Buffer};
try_decode_request(<<16#4B, 16#56, 16#53, 16#01, OpCode, Rest/binary>> = Buffer) ->
    case OpCode of
        16#01 -> % GET
            try_decode_get(Rest, Buffer);
        16#02 -> % PUT
            try_decode_put(Rest, Buffer);
        16#03 -> % DELETE
            try_decode_delete(Rest, Buffer);
        16#04 -> % PING
            {ok, {ping, undefined, undefined}, Rest};
        16#05 -> % STATS
            {ok, {stats, undefined, undefined}, Rest};
        _ ->
            {error, invalid_operation}
    end;
try_decode_request(_) ->
    {error, invalid_magic}.

try_decode_get(Data, OrigBuffer) when byte_size(Data) < 4 ->
    {need_more_data, OrigBuffer};
try_decode_get(<<KeyLen:32/big, Rest/binary>>, OrigBuffer) ->
    if byte_size(Rest) >= KeyLen ->
        <<Key:KeyLen/binary, Remainder/binary>> = Rest,
        {ok, {get, Key, undefined}, Remainder};
    true ->
        {need_more_data, OrigBuffer}
    end.

try_decode_put(Data, OrigBuffer) when byte_size(Data) < 4 ->
    {need_more_data, OrigBuffer};
try_decode_put(<<KeyLen:32/big, Rest/binary>>, OrigBuffer) ->
    if byte_size(Rest) >= KeyLen + 4 ->
        <<Key:KeyLen/binary, ValueLen:32/big, Rest2/binary>> = Rest,
        if byte_size(Rest2) >= ValueLen ->
            <<Value:ValueLen/binary, Remainder/binary>> = Rest2,
            {ok, {put, Key, Value}, Remainder};
        true ->
            {need_more_data, OrigBuffer}
        end;
    true ->
        {need_more_data, OrigBuffer}
    end.

try_decode_delete(Data, OrigBuffer) when byte_size(Data) < 4 ->
    {need_more_data, OrigBuffer};
try_decode_delete(<<KeyLen:32/big, Rest/binary>>, OrigBuffer) ->
    if byte_size(Rest) >= KeyLen ->
        <<Key:KeyLen/binary, Remainder/binary>> = Rest,
        {ok, {delete, Key, undefined}, Remainder};
    true ->
        {need_more_data, OrigBuffer}
    end.

process_request_decoded({get, Key, _}, KvsStore) ->
    case kvs_store:get(KvsStore, Key) of
        {ok, Value} ->
            funnelkvs_protocol:encode_response(success, Value);
        {error, not_found} ->
            funnelkvs_protocol:encode_response(not_found, undefined)
    end;

process_request_decoded({put, Key, Value}, KvsStore) ->
    case kvs_store:put(KvsStore, Key, Value) of
        ok ->
            funnelkvs_protocol:encode_response(success, <<>>);
        _ ->
            funnelkvs_protocol:encode_response(server_error, undefined)
    end;

process_request_decoded({delete, Key, _}, KvsStore) ->
    case kvs_store:delete(KvsStore, Key) of
        ok ->
            funnelkvs_protocol:encode_response(success, <<>>);
        _ ->
            funnelkvs_protocol:encode_response(server_error, undefined)
    end;

process_request_decoded({ping, _, _}, _KvsStore) ->
    funnelkvs_protocol:encode_response(success, <<"pong">>);

process_request_decoded({stats, _, _}, KvsStore) ->
    {ok, Size} = kvs_store:size(KvsStore),
    {ok, Keys} = kvs_store:list_keys(KvsStore),
    NumKeys = length(Keys),
    StatsData = io_lib:format("keys: ~p, size: ~p", [NumKeys, Size]),
    funnelkvs_protocol:encode_response(success, list_to_binary(StatsData)).