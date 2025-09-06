-module(kvs_store).
-behaviour(gen_server).

%% API
-export([start_link/0, stop/1]).
-export([put/3, get/2, delete/2, clear/1]).
-export([size/1, list_keys/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    table :: ets:tid()
}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link(?MODULE, [], []).

stop(Pid) ->
    gen_server:stop(Pid).

put(Pid, Key, Value) when is_binary(Key), is_binary(Value) ->
    gen_server:call(Pid, {put, Key, Value}).

get(Pid, Key) when is_binary(Key) ->
    gen_server:call(Pid, {get, Key}).

delete(Pid, Key) when is_binary(Key) ->
    gen_server:call(Pid, {delete, Key}).

clear(Pid) ->
    gen_server:call(Pid, clear).

size(Pid) ->
    gen_server:call(Pid, size).

list_keys(Pid) ->
    gen_server:call(Pid, list_keys).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    Table = ets:new(kvs_store, [set, private]),
    {ok, #state{table = Table}}.

handle_call({put, Key, Value}, _From, #state{table = Table} = State) ->
    true = ets:insert(Table, {Key, Value}),
    {reply, ok, State};

handle_call({get, Key}, _From, #state{table = Table} = State) ->
    case ets:lookup(Table, Key) of
        [{Key, Value}] ->
            {reply, {ok, Value}, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({delete, Key}, _From, #state{table = Table} = State) ->
    true = ets:delete(Table, Key),
    {reply, ok, State};

handle_call(clear, _From, #state{table = Table} = State) ->
    true = ets:delete_all_objects(Table),
    {reply, ok, State};

handle_call(size, _From, #state{table = Table} = State) ->
    Size = ets:info(Table, size),
    {reply, {ok, Size}, State};

handle_call(list_keys, _From, #state{table = Table} = State) ->
    Keys = ets:foldl(fun({K, _V}, Acc) -> [K | Acc] end, [], Table),
    {reply, {ok, Keys}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{table = Table}) ->
    ets:delete(Table),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.