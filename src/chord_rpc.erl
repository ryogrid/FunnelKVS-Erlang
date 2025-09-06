-module(chord_rpc).
-behaviour(gen_server).

-include("../include/chord.hrl").

%% API
-export([start_server/1, start_server/2, stop_server/1]).
-export([connect/2, disconnect/1, call/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% Internal exports
-export([accept_loop/3, handle_client/2]).

-record(rpc_state, {
    port :: inet:port_number(),
    listen_socket :: gen_tcp:socket(),
    chord_node :: pid(),
    acceptor :: pid()
}).

-define(TIMEOUT, 5000).
-define(RPC_MAGIC, <<"CHRPC">>).
-define(RPC_MAGIC_SIZE, 5).  % Size of "CHRPC"
-define(VERSION, 1).

%%%===================================================================
%%% API
%%%===================================================================

start_server(Port) ->
    start_server(Port, undefined).

start_server(Port, ChordNode) ->
    gen_server:start_link(?MODULE, [Port, ChordNode], []).

stop_server(Pid) ->
    gen_server:stop(Pid).

connect(Host, Port) ->
    case gen_tcp:connect(Host, Port, [binary, {packet, 4}, {active, false}], ?TIMEOUT) of
        {ok, Socket} ->
            % Send handshake
            Handshake = <<?RPC_MAGIC/binary, ?VERSION:8>>,
            case gen_tcp:send(Socket, Handshake) of
                ok ->
                    % Wait for handshake response
                    case gen_tcp:recv(Socket, 0, ?TIMEOUT) of
                        {ok, <<"CHRPC", ?VERSION:8>>} ->
                            {ok, Socket};
                        {ok, _} ->
                            gen_tcp:close(Socket),
                            {error, invalid_handshake};
                        {error, Reason} ->
                            gen_tcp:close(Socket),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    gen_tcp:close(Socket),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

disconnect(Socket) ->
    gen_tcp:close(Socket).

call(Socket, Method, Args) ->
    % Encode the RPC request
    Request = term_to_binary({rpc_request, Method, Args}),
    
    % Send request
    case gen_tcp:send(Socket, Request) of
        ok ->
            % Wait for response
            case gen_tcp:recv(Socket, 0, ?TIMEOUT) of
                {ok, ResponseBin} ->
                    case binary_to_term(ResponseBin) of
                        {rpc_response, ok, Result} ->
                            {ok, Result};
                        {rpc_response, error, Reason} ->
                            {error, Reason};
                        _ ->
                            {error, invalid_response}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Port, ChordNode]) ->
    process_flag(trap_exit, true),
    
    % Open listening socket
    case gen_tcp:listen(Port, [binary, {packet, 4}, {active, false}, 
                               {reuseaddr, true}, {backlog, 100}]) of
        {ok, ListenSocket} ->
            % Start acceptor process
            Acceptor = spawn_link(?MODULE, accept_loop, [ListenSocket, ChordNode, self()]),
            {ok, #rpc_state{
                port = Port,
                listen_socket = ListenSocket,
                chord_node = ChordNode,
                acceptor = Acceptor
            }};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, _Reason}, #rpc_state{acceptor = Pid} = State) ->
    % Restart acceptor if it crashes
    NewAcceptor = spawn_link(?MODULE, accept_loop, 
                            [State#rpc_state.listen_socket, 
                             State#rpc_state.chord_node,
                             self()]),
    {noreply, State#rpc_state{acceptor = NewAcceptor}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #rpc_state{listen_socket = ListenSocket}) ->
    gen_tcp:close(ListenSocket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

accept_loop(ListenSocket, ChordNode, Parent) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            % Spawn a new process to handle this client
            spawn(?MODULE, handle_client, [Socket, ChordNode]),
            accept_loop(ListenSocket, ChordNode, Parent);
        {error, closed} ->
            ok;
        {error, _Reason} ->
            timer:sleep(100),
            accept_loop(ListenSocket, ChordNode, Parent)
    end.

handle_client(Socket, ChordNode) ->
    % Handle handshake
    case gen_tcp:recv(Socket, 0, ?TIMEOUT) of
        {ok, <<"CHRPC", ?VERSION:8>>} ->
            % Send handshake response
            gen_tcp:send(Socket, <<?RPC_MAGIC/binary, ?VERSION:8>>),
            % Handle RPC requests
            handle_rpc_loop(Socket, ChordNode);
        _ ->
            gen_tcp:close(Socket)
    end.

handle_rpc_loop(Socket, ChordNode) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            case binary_to_term(Data) of
                {rpc_request, Method, Args} ->
                    % Process the RPC request
                    Response = process_rpc_request(Method, Args, ChordNode),
                    % Send response
                    ResponseBin = term_to_binary(Response),
                    gen_tcp:send(Socket, ResponseBin),
                    % Continue handling requests
                    handle_rpc_loop(Socket, ChordNode);
                _ ->
                    % Invalid request format
                    Response = {rpc_response, error, invalid_request},
                    ResponseBin = term_to_binary(Response),
                    gen_tcp:send(Socket, ResponseBin),
                    handle_rpc_loop(Socket, ChordNode)
            end;
        {error, closed} ->
            ok;
        {error, _Reason} ->
            gen_tcp:close(Socket)
    end.

process_rpc_request(Method, Args, ChordNode) ->
    try
        Result = case Method of
            find_successor when ChordNode =/= undefined ->
                Successor = chord:find_successor(ChordNode, Args),
                {rpc_response, ok, Successor};
            
            get_predecessor when ChordNode =/= undefined ->
                Pred = chord:get_predecessor(ChordNode),
                {rpc_response, ok, Pred};
            
            notify when ChordNode =/= undefined ->
                ok = chord:notify(ChordNode, Args),
                {rpc_response, ok, ok};
            
            get_successor_list when ChordNode =/= undefined ->
                SuccList = chord:get_successor_list(ChordNode),
                {rpc_response, ok, SuccList};
            
            transfer_keys when ChordNode =/= undefined ->
                {TargetNode, Range} = Args,
                Keys = chord:transfer_keys(ChordNode, TargetNode, Range),
                {rpc_response, ok, Keys};
            
            get_key_value when ChordNode =/= undefined ->
                case chord:get(ChordNode, Args) of
                    {ok, Value} ->
                        {rpc_response, ok, {Args, Value}};
                    {error, not_found} ->
                        {rpc_response, error, not_found}
                end;
            
            put_key_value when ChordNode =/= undefined ->
                {Key, Value} = Args,
                ok = chord:put(ChordNode, Key, Value),
                {rpc_response, ok, ok};
            
            get_id when ChordNode =/= undefined ->
                Id = chord:get_id(ChordNode),
                {rpc_response, ok, Id};
            
            get_successor when ChordNode =/= undefined ->
                Successor = chord:get_successor(ChordNode),
                {rpc_response, ok, Successor};
            
            _ ->
                {rpc_response, error, {unknown_method, Method}}
        end,
        Result
    catch
        Type:Error ->
            {rpc_response, error, {Type, Error}}
    end.