-module(funnelkvs_client).
-behaviour(gen_server).

%% API
-export([connect/2, connect/3, disconnect/1]).
-export([get/2, put/3, delete/2, ping/1, stats/1]).
-export([start/0, parse_command/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    socket :: gen_tcp:socket(),
    host :: string(),
    port :: inet:port_number(),
    timeout :: pos_integer(),
    buffer :: binary()
}).

-define(DEFAULT_TIMEOUT, 5000).

%%%===================================================================
%%% API
%%%===================================================================

connect(Host, Port) ->
    connect(Host, Port, []).

connect(Host, Port, Options) ->
    gen_server:start_link(?MODULE, [Host, Port, Options], []).

disconnect(Pid) ->
    gen_server:stop(Pid).

get(Pid, Key) when is_binary(Key) ->
    gen_server:call(Pid, {get, Key}, ?DEFAULT_TIMEOUT).

put(Pid, Key, Value) when is_binary(Key), is_binary(Value) ->
    gen_server:call(Pid, {put, Key, Value}, ?DEFAULT_TIMEOUT).

delete(Pid, Key) when is_binary(Key) ->
    gen_server:call(Pid, {delete, Key}, ?DEFAULT_TIMEOUT).

ping(Pid) ->
    gen_server:call(Pid, ping, ?DEFAULT_TIMEOUT).

stats(Pid) ->
    gen_server:call(Pid, stats, ?DEFAULT_TIMEOUT).

%% CLI entry point
start() ->
    io:format("FunnelKVS Client~n"),
    io:format("================~n"),
    io:format("Connecting to localhost:8001...~n"),
    
    case connect("localhost", 8001) of
        {ok, Pid} ->
            io:format("Connected!~n"),
            cli_loop(Pid);
        {error, Reason} ->
            io:format("Failed to connect: ~p~n", [Reason])
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Host, Port, Options]) ->
    Timeout = proplists:get_value(timeout, Options, ?DEFAULT_TIMEOUT),
    
    case gen_tcp:connect(Host, Port, [binary, {packet, 0}, {active, false}], Timeout) of
        {ok, Socket} ->
            {ok, #state{socket = Socket,
                       host = Host,
                       port = Port,
                       timeout = Timeout,
                       buffer = <<>>}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call({get, Key}, _From, #state{socket = Socket, timeout = Timeout} = State) ->
    Request = funnelkvs_protocol:encode_request(get, Key, undefined),
    case send_and_receive(Socket, Request, Timeout) of
        {ok, {success, Value}} ->
            {reply, {ok, Value}, State};
        {ok, {not_found, _}} ->
            {reply, {error, not_found}, State};
        {ok, {Status, _}} ->
            {reply, {error, Status}, State};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({put, Key, Value}, _From, #state{socket = Socket, timeout = Timeout} = State) ->
    Request = funnelkvs_protocol:encode_request(put, Key, Value),
    case send_and_receive(Socket, Request, Timeout) of
        {ok, {success, _}} ->
            {reply, ok, State};
        {ok, {Status, _}} ->
            {reply, {error, Status}, State};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({delete, Key}, _From, #state{socket = Socket, timeout = Timeout} = State) ->
    Request = funnelkvs_protocol:encode_request(delete, Key, undefined),
    case send_and_receive(Socket, Request, Timeout) of
        {ok, {success, _}} ->
            {reply, ok, State};
        {ok, {Status, _}} ->
            {reply, {error, Status}, State};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(ping, _From, #state{socket = Socket, timeout = Timeout} = State) ->
    Request = funnelkvs_protocol:encode_request(ping, undefined, undefined),
    case send_and_receive(Socket, Request, Timeout) of
        {ok, {success, Value}} ->
            {reply, {ok, Value}, State};
        {ok, {Status, _}} ->
            {reply, {error, Status}, State};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(stats, _From, #state{socket = Socket, timeout = Timeout} = State) ->
    Request = funnelkvs_protocol:encode_request(stats, undefined, undefined),
    case send_and_receive(Socket, Request, Timeout) of
        {ok, {success, Value}} ->
            {reply, {ok, Value}, State};
        {ok, {Status, _}} ->
            {reply, {error, Status}, State};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{socket = Socket}) ->
    gen_tcp:close(Socket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

send_and_receive(Socket, Request, Timeout) ->
    case gen_tcp:send(Socket, Request) of
        ok ->
            receive_response(Socket, Timeout);
        {error, Reason} ->
            {error, Reason}
    end.

receive_response(Socket, Timeout) ->
    receive_response(Socket, Timeout, <<>>).

receive_response(Socket, Timeout, Buffer) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} ->
            NewBuffer = <<Buffer/binary, Data/binary>>,
            case try_decode_response(NewBuffer) of
                {ok, Response, _Rest} ->
                    {ok, Response};
                {need_more_data} ->
                    receive_response(Socket, Timeout, NewBuffer);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

try_decode_response(Buffer) when byte_size(Buffer) < 9 ->
    {need_more_data};
try_decode_response(<<16#4B, 16#56, 16#53, 16#01, Status, ValueLen:32/big, Rest/binary>> = Buffer) ->
    if byte_size(Rest) >= ValueLen ->
        <<Value:ValueLen/binary, Remainder/binary>> = Rest,
        StatusAtom = decode_status(Status),
        {ok, {StatusAtom, Value}, Remainder};
    true ->
        {need_more_data}
    end;
try_decode_response(_) ->
    {error, invalid_response}.

decode_status(16#00) -> success;
decode_status(16#01) -> not_found;
decode_status(16#02) -> invalid_request;
decode_status(16#03) -> server_error;
decode_status(16#04) -> timeout;
decode_status(16#05) -> not_responsible;
decode_status(_) -> unknown_status.

%%%===================================================================
%%% CLI functions
%%%===================================================================

cli_loop(Pid) ->
    io:format("~nfunnelkvs> "),
    case io:get_line("") of
        eof ->
            disconnect(Pid),
            io:format("~nGoodbye!~n");
        Line ->
            Command = string:trim(Line),
            case parse_command(Command) of
                {get, Key} ->
                    case get(Pid, list_to_binary(Key)) of
                        {ok, Value} ->
                            io:format("Value: ~s~n", [Value]);
                        {error, not_found} ->
                            io:format("Key not found~n");
                        {error, Reason} ->
                            io:format("Error: ~p~n", [Reason])
                    end;
                {put, Key, Value} ->
                    case put(Pid, list_to_binary(Key), list_to_binary(Value)) of
                        ok ->
                            io:format("OK~n");
                        {error, Reason} ->
                            io:format("Error: ~p~n", [Reason])
                    end;
                {delete, Key} ->
                    case delete(Pid, list_to_binary(Key)) of
                        ok ->
                            io:format("OK~n");
                        {error, Reason} ->
                            io:format("Error: ~p~n", [Reason])
                    end;
                ping ->
                    case ping(Pid) of
                        {ok, Response} ->
                            io:format("~s~n", [Response]);
                        {error, Reason} ->
                            io:format("Error: ~p~n", [Reason])
                    end;
                stats ->
                    case stats(Pid) of
                        {ok, StatsData} ->
                            io:format("~s~n", [StatsData]);
                        {error, Reason} ->
                            io:format("Error: ~p~n", [Reason])
                    end;
                quit ->
                    disconnect(Pid),
                    io:format("Goodbye!~n"),
                    erlang:halt(0);
                help ->
                    print_help();
                {error, _} ->
                    io:format("Invalid command. Type 'help' for usage.~n")
            end,
            cli_loop(Pid)
    end.

parse_command(Command) ->
    Tokens = string:tokens(Command, " "),
    case Tokens of
        ["get", Key] -> {get, Key};
        ["GET", Key] -> {get, Key};
        ["put", Key, Value | Rest] -> {put, Key, string:join([Value | Rest], " ")};
        ["PUT", Key, Value | Rest] -> {put, Key, string:join([Value | Rest], " ")};
        ["delete", Key] -> {delete, Key};
        ["DELETE", Key] -> {delete, Key};
        ["del", Key] -> {delete, Key};
        ["DEL", Key] -> {delete, Key};
        ["ping"] -> ping;
        ["PING"] -> ping;
        ["stats"] -> stats;
        ["STATS"] -> stats;
        ["quit"] -> quit;
        ["QUIT"] -> quit;
        ["exit"] -> quit;
        ["EXIT"] -> quit;
        ["help"] -> help;
        ["HELP"] -> help;
        ["?"] -> help;
        _ -> {error, invalid_command}
    end.

print_help() ->
    io:format("~n"),
    io:format("Available commands:~n"),
    io:format("  get <key>           - Retrieve value for key~n"),
    io:format("  put <key> <value>   - Store key-value pair~n"),
    io:format("  delete <key>        - Delete key~n"),
    io:format("  ping                - Check server connection~n"),
    io:format("  stats               - Display server statistics~n"),
    io:format("  help                - Show this help message~n"),
    io:format("  quit                - Exit the client~n"),
    io:format("~n").