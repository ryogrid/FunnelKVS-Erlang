-module(chord).
-behaviour(gen_server).

-include("../include/chord.hrl").

%% API
-export([start_link/1, stop/1]).
-export([start_node/2, stop_node/1, create_ring/1, join_ring/3, leave_ring/1]).
-export([hash/1, generate_node_id/2]).
-export([key_belongs_to/3, between/3]).
-export([init_finger_table/1, find_successor/2]).
-export([get_id/1, get_successor/1, get_predecessor/1, get_finger_table/1, get_successor_list/1]).
-export([put/3, put/4, get/2, get/3, delete/2, delete/3]).
-export([closest_preceding_node/3]).
-export([notify/2, transfer_keys/3]).
-export([get_local_keys/1, get_ring_nodes/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% Internal exports for RPC
-export([handle_find_successor/2, handle_get_predecessor/1, handle_notify/2]).
-export([handle_find_successor_rpc/2, handle_transfer_keys/3]).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Port) ->
    gen_server:start_link(?MODULE, [Port, undefined], []).

stop(Pid) ->
    gen_server:stop(Pid).

%% Multi-node API
start_node(_NodeId, Port) ->
    case start_link(Port) of
        {ok, Pid} -> {ok, Pid};
        Error -> Error
    end.

stop_node(Pid) ->
    stop(Pid).

create_ring(Pid) ->
    gen_server:call(Pid, create_ring).

join_ring(Pid, Host, Port) ->
    gen_server:call(Pid, {join_ring, Host, Port}, 30000).  % Increased timeout for complex joins

leave_ring(Pid) ->
    gen_server:call(Pid, leave_ring, 10000).

get_local_keys(Pid) ->
    gen_server:call(Pid, get_local_keys).

get_ring_nodes(Pid) ->
    gen_server:call(Pid, get_ring_nodes).

hash(Data) when is_list(Data) ->
    hash(list_to_binary(Data));
hash(Data) when is_binary(Data) ->
    <<Hash:160>> = crypto:hash(sha, Data),
    Hash.

generate_node_id(IP, Port) when is_list(IP) ->
    Data = IP ++ ":" ++ integer_to_list(Port),
    hash(Data);
generate_node_id(IP, Port) when is_tuple(IP) ->
    IPStr = inet:ntoa(IP),
    generate_node_id(IPStr, Port).

key_belongs_to(Key, PredId, NodeId) ->
    case PredId < NodeId of
        true ->
            % Normal case: predecessor < node
            (Key > PredId) andalso (Key =< NodeId);
        false ->
            % Wrap-around case: predecessor > node
            (Key > PredId) orelse (Key =< NodeId)
    end.

between(Value, Start, End) ->
    case Start < End of
        true ->
            % Normal case
            (Value > Start) andalso (Value < End);
        false ->
            % Wrap-around case
            (Value > Start) orelse (Value < End)
    end.

init_finger_table(NodeId) ->
    MaxNodes = round(math:pow(2, ?M)),
    lists:map(fun(I) ->
        Start = (NodeId + round(math:pow(2, I-1))) rem MaxNodes,
        IntervalEnd = (NodeId + round(math:pow(2, I))) rem MaxNodes,
        #finger_entry{
            start = Start,
            interval = {Start, IntervalEnd},
            node = undefined
        }
    end, lists:seq(1, ?FINGER_TABLE_SIZE)).

find_successor(Pid, Key) ->
    gen_server:call(Pid, {find_successor, Key}).

get_id(Pid) ->
    gen_server:call(Pid, get_id).

get_successor(Pid) ->
    gen_server:call(Pid, get_successor).

get_predecessor(Pid) ->
    gen_server:call(Pid, get_predecessor).

get_finger_table(Pid) ->
    gen_server:call(Pid, get_finger_table).

get_successor_list(Pid) ->
    gen_server:call(Pid, get_successor_list).

%% Default to quorum consistency
put(Pid, Key, Value) ->
    put(Pid, Key, Value, quorum).

put(Pid, Key, Value, Consistency) ->
    gen_server:call(Pid, {put, Key, Value, Consistency}, 10000).

get(Pid, Key) ->
    get(Pid, Key, quorum).

get(Pid, Key, Consistency) ->
    gen_server:call(Pid, {get, Key, Consistency}, 10000).

delete(Pid, Key) ->
    gen_server:call(Pid, {delete, Key}).

delete(Pid, Key, ConsistencyMode) ->
    gen_server:call(Pid, {delete, Key, ConsistencyMode}).

closest_preceding_node(NodeId, Key, FingerTable) ->
    % Find the closest finger that precedes the key
    ValidFingers = lists:filter(fun(#finger_entry{node = N}) ->
        N =/= undefined
    end, FingerTable),
    
    % Sort fingers by how close they are to the key (in reverse order)
    SortedFingers = lists:sort(fun(#finger_entry{node = N1}, #finger_entry{node = N2}) ->
        between(N1#node_info.id, NodeId, Key) andalso
        (not between(N2#node_info.id, NodeId, Key) orelse
         distance(N1#node_info.id, Key) < distance(N2#node_info.id, Key))
    end, ValidFingers),
    
    case SortedFingers of
        [#finger_entry{node = Best} | _] ->
            case between(Best#node_info.id, NodeId, Key) of
                true -> Best;
                false -> #node_info{id = NodeId}
            end;
        _ ->
            % Return self if no better node found
            #node_info{id = NodeId}
    end.

notify(Pid, Node) ->
    gen_server:call(Pid, {notify, Node}).

transfer_keys(Pid, TargetNode, Range) ->
    gen_server:call(Pid, {transfer_keys, TargetNode, Range}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Port, _JoinNode]) ->  % JoinNode is deprecated, always pass undefined
    % Start KVS store for this node
    {ok, KvsStore} = kvs_store:start_link(),
    
    % Start RPC server for this node
    {ok, RpcServer} = chord_rpc:start_server(Port, self()),
    
    % Generate node ID
    NodeId = generate_node_id("127.0.0.1", Port),
    
    % Create node info for self
    Self = #node_info{
        id = NodeId,
        ip = {127, 0, 0, 1},
        port = Port,
        pid = self()
    },
    
    % Initialize finger table
    FingerTable = init_finger_table(NodeId),
    
    % Initial state
    State = #chord_state{
        self = Self,
        predecessor = undefined,
        successor = Self,  % Initially point to self
        finger_table = FingerTable,
        successor_list = [],
        next_finger = 1,
        kvs_store = KvsStore,
        rpc_server = RpcServer,
        stabilize_timer = undefined,
        fix_fingers_timer = undefined,
        check_pred_timer = undefined
    },
    
    % Start maintenance timers
    State2 = start_maintenance_timers(State),
    
    % JoinNode should always be undefined now (join_ring should be used separately)
    {ok, State2}.

handle_call(get_id, _From, #chord_state{self = Self} = State) ->
    {reply, Self#node_info.id, State};

handle_call(get_successor, _From, #chord_state{successor = Successor} = State) ->
    {reply, Successor, State};

handle_call(get_predecessor, _From, #chord_state{predecessor = Pred} = State) ->
    {reply, Pred, State};

handle_call(get_finger_table, _From, #chord_state{finger_table = FT} = State) ->
    {reply, FT, State};

handle_call(get_successor_list, _From, #chord_state{successor_list = SL} = State) ->
    {reply, SL, State};

handle_call({find_successor, Key}, _From, State) ->
    KeyHash = hash_key(Key),
    Successor = find_successor_internal(KeyHash, State),
    {reply, Successor, State};

% Legacy put without consistency level (defaults to quorum)
handle_call({put, Key, Value}, From, State) ->
    handle_call({put, Key, Value, quorum}, From, State);

% Put with consistency level
handle_call({put, Key, Value, Consistency}, _From, #chord_state{kvs_store = Store, self = Self, successor_list = SuccList} = State) ->
    KeyHash = hash_key(Key),
    ResponsibleNode = find_successor_internal(KeyHash, State),
    
    Result = case ResponsibleNode#node_info.id =:= Self#node_info.id of
        true ->
            % We are responsible for this key
            case Consistency of
                quorum ->
                    % Quorum write - wait for W responses where W = (N+1)/2
                    quorum_put(Store, Key, Value, SuccList);
                eventual ->
                    % Eventual consistency - just store and replicate async
                    kvs_store:put(Store, Key, Value),
                    replicate_to_successors(Key, Value, SuccList),
                    ok;
                _ ->
                    % Default to eventual consistency
                    kvs_store:put(Store, Key, Value),
                    replicate_to_successors(Key, Value, SuccList),
                    ok
            end;
        false ->
            % Forward to responsible node with consistency level
            case forward_to_remote_node(ResponsibleNode, {put, Key, Value, Consistency}) of
                {ok, ok} -> ok;  % Unwrap RPC response
                {ok, Result0} -> Result0;
                Error -> Error
            end
    end,
    {reply, Result, State};

% Legacy get without consistency level (defaults to quorum)
handle_call({get, Key}, From, State) ->
    handle_call({get, Key, quorum}, From, State);

% Get with consistency level
handle_call({get, Key, Consistency}, _From, #chord_state{kvs_store = Store, self = Self, successor_list = SuccList} = State) ->
    KeyHash = hash_key(Key),
    ResponsibleNode = find_successor_internal(KeyHash, State),
    
    Result = case ResponsibleNode#node_info.id =:= Self#node_info.id of
        true ->
            % We are responsible for this key
            case Consistency of
                quorum ->
                    % Quorum read - wait for R responses where R = (N+1)/2
                    quorum_get(Store, Key, SuccList);
                eventual ->
                    % Eventual consistency - just read locally
                    kvs_store:get(Store, Key);
                _ ->
                    % Default to local read
                    kvs_store:get(Store, Key)
            end;
        false ->
            % Forward to responsible node with consistency level
            forward_to_remote_node(ResponsibleNode, {get, Key, Consistency})
    end,
    {reply, Result, State};

handle_call({delete, Key}, _From, #chord_state{kvs_store = Store, self = Self, successor_list = SuccList} = State) ->
    KeyHash = hash_key(Key),
    ResponsibleNode = find_successor_internal(KeyHash, State),
    
    Result = case ResponsibleNode#node_info.id =:= Self#node_info.id of
        true ->
            % We are responsible for this key
            kvs_store:delete(Store, Key),
            % Delete from replicas
            delete_from_successors(Key, SuccList),
            ok;
        false ->
            % Forward to responsible node
            forward_to_remote_node(ResponsibleNode, {delete, Key})
    end,
    {reply, Result, State};

handle_call({delete, Key, ConsistencyMode}, _From, #chord_state{kvs_store = Store, self = Self, successor_list = SuccList} = State) ->
    KeyHash = hash_key(Key),
    ResponsibleNode = find_successor_internal(KeyHash, State),
    
    Result = case ResponsibleNode#node_info.id =:= Self#node_info.id of
        true ->
            % We are responsible for this key
            case ConsistencyMode of
                eventual ->
                    % Eventual consistency - just delete locally and from replicas async
                    kvs_store:delete(Store, Key),
                    delete_from_successors(Key, SuccList),
                    ok;
                quorum ->
                    % Quorum consistency - ensure W nodes delete
                    quorum_delete(Store, Key, SuccList);
                _ ->
                    % Default to quorum
                    quorum_delete(Store, Key, SuccList)
            end;
        false ->
            % Forward to responsible node
            forward_to_remote_node(ResponsibleNode, {delete, Key, ConsistencyMode})
    end,
    {reply, Result, State};

handle_call({get_predecessor_rpc}, _From, #chord_state{predecessor = Pred} = State) ->
    {reply, Pred, State};

handle_call({notify_rpc, Node}, _From, State) ->
    NewState = handle_notify_internal(Node, State),
    {reply, ok, NewState};

handle_call({find_successor_rpc, Key}, _From, State) ->
    Successor = find_successor_internal(Key, State),
    %% Encode node info for RPC response
    Response = encode_node_info(Successor),
    {reply, Response, State};

handle_call({update_successor, NewSucc}, _From, State) ->
    NewState = State#chord_state{successor = NewSucc},
    {reply, ok, NewState};

handle_call({update_predecessor, NewPred}, _From, State) ->
    NewState = State#chord_state{predecessor = NewPred},
    {reply, ok, NewState};

handle_call({receive_keys, KeyValuePairs}, _From, #chord_state{kvs_store = Store} = State) ->
    %% Store received keys
    lists:foreach(fun({Key, Value}) ->
        kvs_store:put(Store, Key, Value)
    end, KeyValuePairs),
    {reply, ok, State};

handle_call({rpc_request, Method, Args}, _From, State) ->
    %% Handle RPC requests from chord_rpc server
    case handle_rpc_request(Method, Args, State) of
        {ok, Response, NewState} ->
            {reply, {ok, Response}, NewState};
        {ok, Response} ->
            {reply, {ok, Response}, State};
        Error ->
            {reply, Error, State}
    end;

handle_call({notify, Node}, _From, State) ->
    NewState = handle_notify_internal(Node, State),
    {reply, ok, NewState};

handle_call(get_state, _From, State) ->
    {reply, {ok, State}, State};

handle_call({put_local, Key, Value}, _From, #chord_state{kvs_store = Store} = State) ->
    Result = kvs_store:put(Store, Key, Value),
    {reply, Result, State};

handle_call({put_replica, Key, Value}, _From, #chord_state{kvs_store = Store} = State) ->
    % Store replica without further replication
    Result = kvs_store:put(Store, Key, Value),
    {reply, Result, State};

handle_call(create_ring, _From, #chord_state{self = Self} = State) ->
    %% Initialize as single node ring
    State2 = State#chord_state{
        predecessor = undefined,
        successor = Self,
        successor_list = []
    },
    %% Start maintenance timers
    State3 = start_maintenance_timers(State2),
    {reply, ok, State3};

handle_call({join_ring, Host, Port}, _From, State) ->
    %% Connect to existing node and join the ring
    case chord_rpc:connect(Host, Port) of
        {ok, Socket} ->
            %% Find our successor through the existing node
            MyId = State#chord_state.self#node_info.id,
            case chord_rpc:call(Socket, find_successor, [MyId]) of
                {ok, SuccessorInfo} ->
                    %% Create node_info from the response
                    Successor = decode_node_info(SuccessorInfo),
                    
                    %% Update our state
                    State2 = State#chord_state{
                        successor = Successor,
                        predecessor = undefined
                    },
                    
                    %% Start maintenance timers
                    State3 = start_maintenance_timers(State2),
                    
                    %% Notify our new successor about us
                    notify_rpc(Successor, State3#chord_state.self),
                    
                    %% Request key transfer from successor
                    transfer_keys_from_successor(State3, Successor),
                    
                    chord_rpc:close(Socket),
                    {reply, ok, State3};
                Error ->
                    chord_rpc:close(Socket),
                    {reply, Error, State}
            end;
        Error ->
            {reply, Error, State}
    end;

handle_call(leave_ring, _From, #chord_state{
    predecessor = Pred,
    successor = Succ,
    kvs_store = Store
} = State) ->
    %% Transfer all our keys to successor
    case Succ of
        #node_info{id = Id} when Id =/= State#chord_state.self#node_info.id ->
            %% Get all local keys
            {ok, AllKeys} = kvs_store:list_keys(Store),
            KeyValuePairs = lists:map(fun(Key) ->
                {ok, Value} = kvs_store:get(Store, Key),
                {Key, Value}
            end, AllKeys),
            
            %% Transfer to successor
            transfer_keys_to_node(Succ, KeyValuePairs),
            
            %% Notify predecessor and successor
            case Pred of
                undefined -> ok;
                _ -> update_successor_on_node(Pred, Succ)
            end,
            update_predecessor_on_node(Succ, Pred);
        _ ->
            ok
    end,
    {reply, ok, State};

handle_call(get_local_keys, _From, #chord_state{kvs_store = Store} = State) ->
    {ok, Keys} = kvs_store:list_keys(Store),
    {reply, Keys, State};

handle_call(get_ring_nodes, _From, State) ->
    %% Traverse the ring to collect all nodes
    Nodes = collect_ring_nodes(State),
    {reply, {ok, Nodes}, State};

handle_call({transfer_keys, TargetNode, Range}, _From, #chord_state{kvs_store = Store} = State) ->
    % Get all keys from local store
    {ok, AllKeys} = kvs_store:list_keys(Store),
    
    % Filter keys that should be transferred
    TransferredKeys = case Range of
        {StartId, EndId} ->
            lists:filter(fun(Key) ->
                KeyHash = hash_key(Key),
                key_belongs_to(KeyHash, StartId, EndId)
            end, AllKeys);
        range ->
            % Transfer keys that should belong to TargetNode
            lists:filter(fun(Key) ->
                KeyHash = hash_key(Key),
                should_transfer_key(KeyHash, State#chord_state.self#node_info.id, TargetNode#node_info.id)
            end, AllKeys)
    end,
    
    % Build list of key-value pairs to transfer
    KeyValuePairs = lists:map(fun(Key) ->
        {ok, Value} = kvs_store:get(Store, Key),
        {Key, Value}
    end, TransferredKeys),
    
    {reply, KeyValuePairs, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({update_successor, NewSucc}, State) ->
    % Update successor list when successor changes
    NewState = update_successor_list(NewSucc, State),
    {noreply, NewState#chord_state{successor = NewSucc}};

handle_cast({update_successor_list_only}, #chord_state{successor = Successor} = State) ->
    % Update successor list without changing successor
    NewState = update_successor_list(Successor, State),
    {noreply, NewState};

handle_cast({update_predecessor, NewPred}, State) ->
    {noreply, State#chord_state{predecessor = NewPred}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(stabilize, State) ->
    %% Schedule next stabilization
    erlang:send_after(?STABILIZE_INTERVAL, self(), stabilize),
    %% Run stabilization in a separate process to avoid blocking
    Self = self(),
    spawn(fun() -> do_stabilize_async(Self, State) end),
    {noreply, State};

handle_info(fix_fingers, State) ->
    NewState = fix_fingers(State),
    {noreply, NewState};

handle_info({notify_new_successor, Node}, #chord_state{self = Self} = State) ->
    %% Send reciprocal notify to establish bidirectional link in two-node ring
    notify_rpc(Node, Self),
    {noreply, State};

handle_info(check_predecessor, State) ->
    NewState = check_predecessor(State),
    {noreply, NewState};

handle_info(sync_replicas, State) ->
    % Schedule next sync
    erlang:send_after(?REPLICATE_INTERVAL, self(), sync_replicas),
    % Sync replicas asynchronously
    spawn(fun() -> sync_replicas_async(State) end),
    {noreply, State};

handle_info(redistribute_replicas, State) ->
    % Handle replica redistribution after predecessor change
    spawn(fun() -> redistribute_replicas_async(State) end),
    {noreply, State};

handle_info(recover_replicas, State) ->
    % Handle replica recovery after node failure
    spawn(fun() -> recover_replicas_async(State) end),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #chord_state{kvs_store = Store, rpc_server = RpcServer} = State) ->
    stop_maintenance_timers(State),
    kvs_store:stop(Store),
    case RpcServer of
        undefined -> ok;
        Pid -> chord_rpc:stop_server(Pid)
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

start_maintenance_timers(State) ->
    StabilizeTimer = erlang:send_after(?STABILIZE_INTERVAL, self(), stabilize),
    FixFingersTimer = erlang:send_after(?FIX_FINGERS_INTERVAL, self(), fix_fingers),
    CheckPredTimer = erlang:send_after(?CHECK_PREDECESSOR_INTERVAL, self(), check_predecessor),
    erlang:send_after(?REPLICATE_INTERVAL, self(), sync_replicas),
    
    State#chord_state{
        stabilize_timer = StabilizeTimer,
        fix_fingers_timer = FixFingersTimer,
        check_pred_timer = CheckPredTimer
    }.

stop_maintenance_timers(#chord_state{
    stabilize_timer = ST,
    fix_fingers_timer = FFT,
    check_pred_timer = CPT
}) ->
    cancel_timer(ST),
    cancel_timer(FFT),
    cancel_timer(CPT).

cancel_timer(undefined) -> ok;
cancel_timer(Timer) -> erlang:cancel_timer(Timer).


do_stabilize_async(NodePid, #chord_state{self = Self, successor = Successor, predecessor = Pred, successor_list = SuccList}) ->
    % Special case: if we have no predecessor and successor is self,
    % check if there's a new node between us
    case Successor#node_info.id =:= Self#node_info.id andalso Pred =/= undefined of
        true ->
            % Someone joined, make them our successor
            gen_server:cast(NodePid, {update_successor, Pred});
        false when Successor#node_info.id =:= Self#node_info.id ->
            ok;  % Still alone in the ring
        false ->
            % First check if successor is alive
            case is_alive(Successor) of
                false ->
                    % Successor has failed, use next in successor list or predecessor
                    NewSucc = case SuccList of
                        [First | _] -> First;
                        [] -> case Pred of
                            undefined -> Self;
                            _ -> Pred
                        end
                    end,
                    gen_server:cast(NodePid, {update_successor, NewSucc}),
                    % Trigger replica recovery after successor failure
                    erlang:send_after(500, NodePid, recover_replicas);
                true ->
                    % Check if successor's predecessor is between us and successor
                    case get_predecessor_rpc(Successor) of
                        {ok, SuccPred} when SuccPred =/= undefined ->
                            case between(SuccPred#node_info.id, Self#node_info.id, Successor#node_info.id) of
                                true ->
                                    % Update our successor
                                    gen_server:cast(NodePid, {update_successor, SuccPred}),
                                    % Notify the new successor
                                    notify_rpc(SuccPred, Self);
                                false ->
                                    % Notify our successor
                                    notify_rpc(Successor, Self),
                                    % Update successor list
                                    gen_server:cast(NodePid, {update_successor_list_only})
                            end;
                        _ ->
                            % Notify our successor anyway
                            notify_rpc(Successor, Self),
                            % Update successor list
                            gen_server:cast(NodePid, {update_successor_list_only})
                    end
            end
    end.

fix_fingers(#chord_state{
    finger_table = FingerTable,
    next_finger = NextFinger
} = State) ->
    % Reschedule timer
    erlang:send_after(?FIX_FINGERS_INTERVAL, self(), fix_fingers),
    
    % Fix one finger
    Finger = lists:nth(NextFinger, FingerTable),
    SuccessorNode = find_successor_internal(Finger#finger_entry.start, State),
    
    % Update finger table
    UpdatedFinger = Finger#finger_entry{node = SuccessorNode},
    % Replace the finger at position NextFinger
    {Before, [_ | After]} = lists:split(NextFinger - 1, FingerTable),
    UpdatedFingerTable = Before ++ [UpdatedFinger | After],
    
    % Move to next finger
    NextFinger2 = case NextFinger >= ?FINGER_TABLE_SIZE of
        true -> 1;
        false -> NextFinger + 1
    end,
    
    State#chord_state{
        finger_table = UpdatedFingerTable,
        next_finger = NextFinger2
    }.

check_predecessor(#chord_state{predecessor = Pred} = State) ->
    % Reschedule timer
    erlang:send_after(?CHECK_PREDECESSOR_INTERVAL, self(), check_predecessor),
    
    case Pred of
        undefined ->
            State;
        _ ->
            % Check if predecessor is alive
            case is_alive(Pred) of
                true ->
                    State;
                false ->
                    % Predecessor has failed - trigger replica recovery
                    erlang:send_after(500, self(), recover_replicas),
                    State#chord_state{predecessor = undefined}
            end
    end.

update_successor_list(NewSucc, #chord_state{self = Self, successor_list = OldList} = State) ->
    % Build successor list by getting successor's successor list
    case NewSucc#node_info.id =:= Self#node_info.id of
        true ->
            % Single node ring
            State#chord_state{successor_list = []};
        false ->
            % Get successor's successor list and prepend our successor
            case get_successor_list_rpc(NewSucc) of
                {ok, SuccList} ->
                    % Build list: our successor + its successors (up to SUCCESSOR_LIST_SIZE total)
                    AllSuccessors = [NewSucc | SuccList],
                    % Remove ourselves and duplicates, limit to SUCCESSOR_LIST_SIZE
                    FilteredList = lists:filter(fun(N) -> 
                        N#node_info.id =/= Self#node_info.id
                    end, AllSuccessors),
                    UniqList = lists:usort(fun(A, B) -> 
                        A#node_info.id =< B#node_info.id 
                    end, FilteredList),
                    NewList = lists:sublist(UniqList, ?SUCCESSOR_LIST_SIZE),
                    State#chord_state{successor_list = NewList};
                _ ->
                    % If we can't get the list, just use the new successor
                    State#chord_state{successor_list = [NewSucc]}
            end
    end.

get_successor_list_rpc(#node_info{ip = IP, port = Port}) ->
    case chord_rpc:connect(inet:ntoa(IP), Port) of
        {ok, Socket} ->
            Result = chord_rpc:call(Socket, get_successor_list, []),
            chord_rpc:close(Socket),
            case Result of
                {ok, EncodedList} ->
                    DecodedList = [decode_node_info(NodeInfo) || NodeInfo <- EncodedList],
                    {ok, DecodedList};
                Error -> Error
            end;
        Error -> Error
    end.


get_successor_rpc(#node_info{ip = IP, port = Port}) ->
    case chord_rpc:connect(inet:ntoa(IP), Port) of
        {ok, Socket} ->
            Result = chord_rpc:call(Socket, get_successor, []),
            chord_rpc:close(Socket),
            case Result of
                {ok, SuccInfo} -> {ok, decode_node_info(SuccInfo)};
                Error -> Error
            end;
        Error -> Error
    end.

replicate_to_successors(_Key, _Value, []) ->
    ok;
replicate_to_successors(Key, Value, SuccList) ->
    % Replicate to up to REPLICATION_FACTOR-1 successors (we already have one copy)
    ReplicaNodes = lists:sublist(SuccList, ?REPLICATION_FACTOR - 1),
    lists:foreach(fun(Node) ->
        spawn(fun() -> replicate_to_node(Node, Key, Value) end)
    end, ReplicaNodes),
    ok.

replicate_to_node(#node_info{ip = IP, port = Port}, Key, Value) ->
    case chord_rpc:connect(inet:ntoa(IP), Port) of
        {ok, Socket} ->
            chord_rpc:call(Socket, put_replica, [Key, Value]),
            chord_rpc:close(Socket);
        _ ->
            % Replication failed, will be retried in next sync
            ok
    end.

delete_from_successors(_Key, []) ->
    ok;
delete_from_successors(Key, SuccList) ->
    % Delete from up to REPLICATION_FACTOR-1 successors
    ReplicaNodes = lists:sublist(SuccList, ?REPLICATION_FACTOR - 1),
    lists:foreach(fun(Node) ->
        spawn(fun() -> delete_from_node(Node, Key) end)
    end, ReplicaNodes),
    ok.

delete_from_node(#node_info{ip = IP, port = Port}, Key) ->
    case chord_rpc:connect(inet:ntoa(IP), Port) of
        {ok, Socket} ->
            chord_rpc:call(Socket, delete_replica, [Key]),
            chord_rpc:close(Socket);
        _ ->
            % Delete failed, will be handled in next sync
            ok
    end.

sync_replicas_async(#chord_state{kvs_store = Store, self = Self, successor_list = SuccList, predecessor = Pred}) ->
    % Get all keys we are responsible for (as primary)
    {ok, AllKeys} = kvs_store:list_keys(Store),
    
    % Filter keys we are primary for
    PrimaryKeys = lists:filter(fun(Key) ->
        KeyHash = hash_key(Key),
        AmIPrimary = case Pred of
            undefined -> true;  % We're the only node
            _ -> key_belongs_to(KeyHash, Pred#node_info.id, Self#node_info.id)
        end,
        AmIPrimary
    end, AllKeys),
    
    % Ensure these keys are replicated to successors
    case SuccList of
        [] -> ok;
        _ ->
            ReplicaNodes = lists:sublist(SuccList, ?REPLICATION_FACTOR - 1),
            lists:foreach(fun(Key) ->
                {ok, Value} = kvs_store:get(Store, Key),
                lists:foreach(fun(Node) ->
                    % Check if replica exists and sync if needed
                    sync_replica_to_node(Node, Key, Value)
                end, ReplicaNodes)
            end, PrimaryKeys)
    end,
    ok.

redistribute_replicas_async(#chord_state{kvs_store = Store, self = Self, successor_list = SuccList, predecessor = Pred}) ->
    % After a predecessor change, we need to:
    % 1. Remove replicas we no longer need to hold
    % 2. Ensure we have replicas we should now hold
    
    {ok, AllKeys} = kvs_store:list_keys(Store),
    
    % Find keys we should no longer have (neither primary nor replica)
    KeysToRemove = lists:filter(fun(Key) ->
        KeyHash = hash_key(Key),
        
        % Check if we're the primary for this key
        AmIPrimary = case Pred of
            undefined -> true;
            _ -> key_belongs_to(KeyHash, Pred#node_info.id, Self#node_info.id)
        end,
        
        case AmIPrimary of
            true -> false;  % We're primary, keep it
            false ->
                % Check if we should be a replica holder
                % Find the primary node for this key
                PrimaryNode = find_primary_node(KeyHash, Self, Pred, SuccList),
                case PrimaryNode of
                    Self -> false;  % We're actually the primary (edge case)
                    _ ->
                        % Check if we're in the replica set for this key
                        ReplicaSet = get_replica_set(PrimaryNode, SuccList),
                        not lists:member(Self, ReplicaSet)
                end
        end
    end, AllKeys),
    
    % Remove keys we shouldn't have
    lists:foreach(fun(Key) ->
        kvs_store:delete(Store, Key)
    end, KeysToRemove),
    
    % Request replicas we should have from predecessors
    % This is handled by the periodic sync_replicas process
    ok.

recover_replicas_async(#chord_state{kvs_store = Store, self = Self, successor_list = SuccList, predecessor = Pred}) ->
    % After a node failure, we need to ensure replication factor is maintained
    % This is called when predecessor fails or when successor fails
    
    {ok, AllKeys} = kvs_store:list_keys(Store),
    
    % Filter keys we are primary for
    PrimaryKeys = lists:filter(fun(Key) ->
        KeyHash = hash_key(Key),
        case Pred of
            undefined -> true;  % We might be the only node or first after failure
            _ -> key_belongs_to(KeyHash, Pred#node_info.id, Self#node_info.id)
        end
    end, AllKeys),
    
    % Ensure replication factor for our primary keys
    case SuccList of
        [] -> ok;  % No successors available
        _ ->
            % We need N-1 replicas (we hold the primary copy)
            RequiredReplicas = ?REPLICATION_FACTOR - 1,
            ReplicaNodes = lists:sublist(SuccList, RequiredReplicas),
            
            % Re-replicate all primary keys to ensure replication factor
            lists:foreach(fun(Key) ->
                {ok, Value} = kvs_store:get(Store, Key),
                lists:foreach(fun(Node) ->
                    % Force replication to maintain replication factor
                    spawn(fun() -> replicate_to_node(Node, Key, Value) end)
                end, ReplicaNodes)
            end, PrimaryKeys)
    end,
    ok.

sync_replica_to_node(#node_info{ip = IP, port = Port}, Key, Value) ->
    case chord_rpc:connect(inet:ntoa(IP), Port) of
        {ok, Socket} ->
            % Check if replica exists
            case chord_rpc:call(Socket, get_replica, [Key]) of
                {ok, {ok, _ExistingValue}} ->
                    % Replica exists, could check if update needed
                    ok;
                _ ->
                    % Replica missing, replicate it
                    chord_rpc:call(Socket, put_replica, [Key, Value])
            end,
            chord_rpc:close(Socket);
        _ ->
            % Node unreachable, skip
            ok
    end.

quorum_delete(Store, Key, SuccList) ->
    % Calculate quorum size: W = (N+1)/2
    W = (?REPLICATION_FACTOR + 1) div 2,
    
    % Delete locally first
    kvs_store:delete(Store, Key),
    LocalWrite = 1,
    
    % Get replica nodes
    ReplicaNodes = lists:sublist(SuccList, ?REPLICATION_FACTOR - 1),
    
    % Spawn delete operations to replicas
    Parent = self(),
    Ref = make_ref(),
    lists:foreach(fun(Node) ->
        spawn(fun() ->
            case delete_from_node(Node, Key) of
                ok -> Parent ! {Ref, success};
                _ -> Parent ! {Ref, failure}
            end
        end)
    end, ReplicaNodes),
    
    % Collect responses with timeout
    Timeout = 5000,
    SuccessCount = collect_quorum_responses(Ref, length(ReplicaNodes), LocalWrite, W, Timeout),
    
    if
        SuccessCount >= W ->
            ok;
        true ->
            {error, insufficient_replicas}
    end.

%% Quorum-based operations
quorum_put(Store, Key, Value, SuccList) ->
    % Calculate quorum size: W = (N+1)/2
    W = (?REPLICATION_FACTOR + 1) div 2,
    
    % Store locally first
    kvs_store:put(Store, Key, Value),
    LocalWrite = 1,
    
    % Get replica nodes
    ReplicaNodes = lists:sublist(SuccList, ?REPLICATION_FACTOR - 1),
    
    % Spawn write operations to replicas
    Parent = self(),
    Ref = make_ref(),
    
    lists:foreach(fun(Node) ->
        spawn(fun() ->
            Result = write_to_replica(Node, Key, Value),
            Parent ! {Ref, Result}
        end)
    end, ReplicaNodes),
    
    % Collect responses
    WriteCount = collect_quorum_responses(Ref, length(ReplicaNodes), LocalWrite, W, 5000),
    
    % Return success if we got enough writes
    case WriteCount >= W of
        true -> ok;
        false -> {error, insufficient_replicas}
    end.

quorum_get(Store, Key, SuccList) ->
    % Calculate quorum size: R = (N+1)/2  
    R = (?REPLICATION_FACTOR + 1) div 2,
    
    % Read locally first
    LocalValue = kvs_store:get(Store, Key),
    LocalRead = case LocalValue of
        {ok, _} -> 1;
        _ -> 0
    end,
    
    % Get replica nodes
    ReplicaNodes = lists:sublist(SuccList, ?REPLICATION_FACTOR - 1),
    
    % Spawn read operations from replicas
    Parent = self(),
    Ref = make_ref(),
    
    lists:foreach(fun(Node) ->
        spawn(fun() ->
            Result = read_from_replica(Node, Key),
            Parent ! {Ref, Result}
        end)
    end, ReplicaNodes),
    
    % Collect responses
    Values = case LocalValue of
        {ok, V} -> [{V, 1}];
        _ -> []
    end,
    AllValues = collect_read_responses(Ref, length(ReplicaNodes), Values, R, 5000),
    
    % Return the most common value (simple conflict resolution)
    case AllValues of
        [] -> {error, not_found};
        _ ->
            % Get the value with highest count (most recent for ties)
            [{Value, _Count} | _] = lists:sort(fun({_, C1}, {_, C2}) -> C1 >= C2 end, AllValues),
            {ok, Value}
    end.

write_to_replica(#node_info{ip = IP, port = Port}, Key, Value) ->
    case chord_rpc:connect(inet:ntoa(IP), Port) of
        {ok, Socket} ->
            Result = chord_rpc:call(Socket, put_replica, [Key, Value]),
            chord_rpc:close(Socket),
            case Result of
                {ok, ok} -> ok;
                _ -> error
            end;
        _ ->
            error
    end.

read_from_replica(#node_info{ip = IP, port = Port}, Key) ->
    case chord_rpc:connect(inet:ntoa(IP), Port) of
        {ok, Socket} ->
            Result = chord_rpc:call(Socket, get_replica, [Key]),
            chord_rpc:close(Socket),
            Result;
        _ ->
            {error, unreachable}
    end.

collect_quorum_responses(_Ref, 0, Acc, _Needed, _Timeout) ->
    Acc;
collect_quorum_responses(Ref, Remaining, Acc, Needed, Timeout) when Acc >= Needed ->
    % We have enough responses, drain remaining messages
    receive
        {Ref, _} -> collect_quorum_responses(Ref, Remaining - 1, Acc, Needed, 0)
    after 0 ->
        Acc
    end;
collect_quorum_responses(Ref, Remaining, Acc, Needed, Timeout) ->
    receive
        {Ref, ok} ->
            collect_quorum_responses(Ref, Remaining - 1, Acc + 1, Needed, Timeout);
        {Ref, _} ->
            collect_quorum_responses(Ref, Remaining - 1, Acc, Needed, Timeout)
    after Timeout ->
        Acc
    end.

collect_read_responses(_Ref, 0, Values, _Needed, _Timeout) ->
    Values;
collect_read_responses(Ref, Remaining, Values, Needed, Timeout) when length(Values) >= Needed ->
    % We have enough responses, drain remaining
    receive
        {Ref, _} -> collect_read_responses(Ref, Remaining - 1, Values, Needed, 0)
    after 0 ->
        Values
    end;
collect_read_responses(Ref, Remaining, Values, Needed, Timeout) ->
    receive
        {Ref, {ok, {ok, Value}}} ->
            % Update value count
            NewValues = update_value_count(Value, Values),
            collect_read_responses(Ref, Remaining - 1, NewValues, Needed, Timeout);
        {Ref, _} ->
            collect_read_responses(Ref, Remaining - 1, Values, Needed, Timeout)
    after Timeout ->
        Values
    end.

update_value_count(Value, Values) ->
    case lists:keyfind(Value, 1, Values) of
        {Value, Count} ->
            lists:keyreplace(Value, 1, Values, {Value, Count + 1});
        false ->
            [{Value, 1} | Values]
    end.

find_successor_internal(Key, #chord_state{
    self = Self,
    successor = Successor,
    predecessor = Pred,
    finger_table = FingerTable
} = _State) ->
    % In single-node ring, we handle all keys
    case Successor#node_info.id =:= Self#node_info.id of
        true ->
            Self;  % Return self as successor in single-node ring
        false ->
            % Check if we are responsible for this key
            % A node is responsible for a key if the key falls between its predecessor and itself
            AmIResponsible = case Pred of
                undefined -> 
                    % If no predecessor, check against successor
                    key_belongs_to(Key, Self#node_info.id, Successor#node_info.id);
                _ ->
                    key_belongs_to(Key, Pred#node_info.id, Self#node_info.id)
            end,
            
            case AmIResponsible of
                true ->
                    Self;  % We are responsible
                false ->
                    % Check if successor is responsible
                    case key_belongs_to(Key, Self#node_info.id, Successor#node_info.id) of
                        true ->
                            Successor;
                        false ->
                            % Find closest preceding node
                            ClosestNode = closest_preceding_node(Self#node_info.id, Key, FingerTable),
                            case ClosestNode#node_info.id =:= Self#node_info.id of
                                true ->
                                    % We are the closest, return our successor
                                    Successor;
                                false ->
                                    % RPC to find successor on remote node
                                    case find_successor_on_remote_node(ClosestNode, Key) of
                                        {ok, RemoteSuccessor} -> RemoteSuccessor;
                                        _ -> Successor
                                    end
                            end
                    end
            end
    end.

handle_notify_internal(Node, #chord_state{self = Self, predecessor = Pred, successor = Succ, kvs_store = Store} = State) ->
    %% Check if we should update predecessor
    OldPred = Pred,
    State2 = case Pred of
        undefined ->
            State#chord_state{predecessor = Node};
        _ ->
            case between(Node#node_info.id, Pred#node_info.id, Self#node_info.id) of
                true ->
                    State#chord_state{predecessor = Node};
                false ->
                    State
            end
    end,
    
    %% If predecessor changed, handle replica redistribution
    State3 = case State2#chord_state.predecessor of
        OldPred ->
            State2;  % No change
        NewPred ->
            % Predecessor changed - need to handle key/replica redistribution
            % 1. Transfer keys that now belong to the new predecessor
            transfer_keys_to_new_predecessor(Store, OldPred, NewPred, Self),
            % 2. Schedule replica redistribution
            erlang:send_after(1000, self(), redistribute_replicas),
            State2
    end,
    
    %% If we are our own successor (single node ring) and a new node is notifying us,
    %% it should become our successor (for initial ring formation)
    State4 = case Succ#node_info.id =:= Self#node_info.id andalso Node#node_info.id =/= Self#node_info.id of
        true ->
            %% In a single-node ring that gets a notify, the new node should become our successor
            %% Schedule a reciprocal notify after a short delay
            erlang:send_after(100, self(), {notify_new_successor, Node}),
            State3#chord_state{successor = Node};
        false ->
            State3
    end,
    State4.

get_predecessor_rpc(#node_info{pid = Pid}) when Pid =:= self() ->
    {error, self_reference};
get_predecessor_rpc(#node_info{pid = Pid}) when is_pid(Pid) ->
    gen_server:call(Pid, {get_predecessor_rpc});
get_predecessor_rpc(#node_info{ip = IP, port = Port}) ->
    %% RPC to remote node
    case chord_rpc:connect(inet:ntoa(IP), Port) of
        {ok, Socket} ->
            Result = chord_rpc:call(Socket, get_predecessor, []),
            chord_rpc:close(Socket),
            case Result of
                {ok, PredInfo} -> {ok, decode_node_info(PredInfo)};
                Error -> Error
            end;
        Error -> Error
    end.

notify_rpc(#node_info{pid = Pid}, Node) when is_pid(Pid) ->
    gen_server:call(Pid, {notify_rpc, Node});
notify_rpc(#node_info{ip = IP, port = Port}, Node) ->
    %% RPC to remote node
    case chord_rpc:connect(inet:ntoa(IP), Port) of
        {ok, Socket} ->
            NodeInfo = encode_node_info(Node),
            Result = chord_rpc:call(Socket, notify, [NodeInfo]),
            chord_rpc:close(Socket),
            Result;
        Error -> Error
    end.

is_alive(#node_info{pid = Pid}) when is_pid(Pid) ->
    erlang:is_process_alive(Pid);
is_alive(#node_info{ip = IP, port = Port}) ->
    %% Ping remote node
    case chord_rpc:connect(inet:ntoa(IP), Port) of
        {ok, Socket} ->
            chord_rpc:close(Socket),
            true;
        _ -> false
    end.

hash_key(Key) when is_binary(Key) ->
    hash(Key);
hash_key(Key) ->
    hash_key(term_to_binary(Key)).

parse_ip(IP) when is_list(IP) ->
    {ok, Addr} = inet:parse_address(IP),
    Addr;
parse_ip(IP) when is_tuple(IP) ->
    IP.

distance(From, To) ->
    MaxNodes = round(math:pow(2, ?M)),
    case To >= From of
        true -> To - From;
        false -> MaxNodes - From + To
    end.

should_transfer_key(KeyHash, OurId, TargetId) ->
    % Key should be transferred if TargetId is closer to the key than we are
    % This is used during node join to transfer keys to the new node
    DistanceToUs = distance(KeyHash, OurId),
    DistanceToTarget = distance(KeyHash, TargetId),
    DistanceToTarget < DistanceToUs.

%% RPC handlers
handle_find_successor(Key, State) ->
    find_successor_internal(Key, State).

handle_find_successor_rpc(Key, State) ->
    Successor = find_successor_internal(Key, State),
    encode_node_info(Successor).

handle_get_predecessor(#chord_state{predecessor = Pred}) ->
    Pred.

handle_notify(Node, State) ->
    handle_notify_internal(Node, State).

handle_transfer_keys(_TargetNode, Range, #chord_state{kvs_store = Store}) ->
    {ok, AllKeys} = kvs_store:list_keys(Store),
    TransferredKeys = case Range of
        {StartId, EndId} ->
            lists:filter(fun(Key) ->
                KeyHash = hash_key(Key),
                key_belongs_to(KeyHash, StartId, EndId)
            end, AllKeys);
        _ -> []
    end,
    
    KeyValuePairs = lists:map(fun(Key) ->
        {ok, Value} = kvs_store:get(Store, Key),
        {Key, Value}
    end, TransferredKeys),
    KeyValuePairs.

%% RPC request handler
handle_rpc_request(find_successor, [Key], State) ->
    Successor = find_successor_internal(Key, State),
    {ok, encode_node_info(Successor)};
handle_rpc_request(get_predecessor, [], #chord_state{predecessor = Pred}) ->
    case Pred of
        undefined -> {ok, undefined};
        _ -> {ok, encode_node_info(Pred)}
    end;
handle_rpc_request(get_successor, [], #chord_state{successor = Succ}) ->
    {ok, encode_node_info(Succ)};
handle_rpc_request(get_successor_list, [], #chord_state{successor_list = SuccList}) ->
    EncodedList = [encode_node_info(Node) || Node <- SuccList],
    {ok, EncodedList};
handle_rpc_request(notify, [NodeInfo], State) ->
    Node = decode_node_info(NodeInfo),
    NewState = handle_notify_internal(Node, State),
    {ok, ok, NewState};
% Handle put with consistency level
handle_rpc_request(put, [Key, Value, Consistency], #chord_state{kvs_store = Store, self = Self, successor_list = SuccList} = State) ->
    KeyHash = hash_key(Key),
    ResponsibleNode = find_successor_internal(KeyHash, State),
    case ResponsibleNode#node_info.id =:= Self#node_info.id of
        true ->
            Result = case Consistency of
                quorum ->
                    quorum_put(Store, Key, Value, SuccList);
                _ ->
                    kvs_store:put(Store, Key, Value),
                    replicate_to_successors(Key, Value, SuccList),
                    ok
            end,
            {ok, Result};
        false ->
            forward_to_remote_node(ResponsibleNode, {put, Key, Value, Consistency})
    end;
% Handle legacy put without consistency level
handle_rpc_request(put, [Key, Value], State) ->
    handle_rpc_request(put, [Key, Value, eventual], State);
handle_rpc_request(put_replica, [Key, Value], #chord_state{kvs_store = Store}) ->
    % Store replica without further replication
    kvs_store:put(Store, Key, Value),
    {ok, ok};
% Handle get with consistency level
handle_rpc_request(get, [Key, Consistency], #chord_state{kvs_store = Store, self = Self, successor_list = SuccList} = State) ->
    KeyHash = hash_key(Key),
    ResponsibleNode = find_successor_internal(KeyHash, State),
    case ResponsibleNode#node_info.id =:= Self#node_info.id of
        true ->
            case Consistency of
                quorum ->
                    quorum_get(Store, Key, SuccList);
                _ ->
                    kvs_store:get(Store, Key)
            end;
        false ->
            forward_to_remote_node(ResponsibleNode, {get, Key, Consistency})
    end;
% Handle legacy get without consistency level  
handle_rpc_request(get, [Key], State) ->
    handle_rpc_request(get, [Key, eventual], State);
handle_rpc_request(delete, [Key], #chord_state{kvs_store = Store, self = Self, successor_list = SuccList} = State) ->
    KeyHash = hash_key(Key),
    ResponsibleNode = find_successor_internal(KeyHash, State),
    case ResponsibleNode#node_info.id =:= Self#node_info.id of
        true ->
            kvs_store:delete(Store, Key),
            % Delete from replicas
            delete_from_successors(Key, SuccList),
            {ok, ok};
        false ->
            forward_to_remote_node(ResponsibleNode, {delete, Key})
    end;
handle_rpc_request(delete_replica, [Key], #chord_state{kvs_store = Store}) ->
    % Delete replica
    kvs_store:delete(Store, Key),
    {ok, ok};
handle_rpc_request(get_replica, [Key], #chord_state{kvs_store = Store}) ->
    % Get replica value directly from store
    Result = kvs_store:get(Store, Key),
    {ok, Result};
handle_rpc_request(transfer_keys, [NodeId], #chord_state{kvs_store = Store, self = Self}) ->
    {ok, AllKeys} = kvs_store:list_keys(Store),
    TransferredKeys = lists:filter(fun(Key) ->
        KeyHash = hash_key(Key),
        should_transfer_key(KeyHash, Self#node_info.id, NodeId)
    end, AllKeys),
    KeyValuePairs = lists:map(fun(Key) ->
        {ok, Value} = kvs_store:get(Store, Key),
        % Delete the key from our store since we're transferring it
        kvs_store:delete(Store, Key),
        {Key, Value}
    end, TransferredKeys),
    {ok, KeyValuePairs};
handle_rpc_request(receive_keys, [KeyValuePairs], #chord_state{kvs_store = Store}) ->
    lists:foreach(fun({Key, Value}) ->
        kvs_store:put(Store, Key, Value)
    end, KeyValuePairs),
    {ok, ok};
handle_rpc_request(update_successor, [SuccInfo], _State) ->
    _NewSucc = decode_node_info(SuccInfo),
    % Note: State update should be done in handle_call
    {ok, ok};
handle_rpc_request(update_predecessor, [PredInfo], _State) ->
    _NewPred = case PredInfo of
        undefined -> undefined;
        _ -> decode_node_info(PredInfo)
    end,
    % Note: State update should be done in handle_call
    {ok, ok};
handle_rpc_request(_Method, _Args, _State) ->
    {error, unknown_method}.

%% Helper functions for multi-node operations
encode_node_info(#node_info{id = Id, ip = IP, port = Port, pid = _Pid}) ->
    {Id, inet:ntoa(IP), Port}.

decode_node_info(undefined) ->
    undefined;
decode_node_info({Id, IPStr, Port}) ->
    {ok, IP} = inet:parse_address(IPStr),
    #node_info{id = Id, ip = IP, port = Port, pid = undefined}.

forward_to_remote_node(#node_info{ip = IP, port = Port}, Request) ->
    case chord_rpc:connect(inet:ntoa(IP), Port) of
        {ok, Socket} ->
            Result = case Request of
                {put, Key, Value, Consistency} ->
                    chord_rpc:call(Socket, put, [Key, Value, Consistency]);
                {put, Key, Value} ->
                    chord_rpc:call(Socket, put, [Key, Value]);
                {get, Key, Consistency} ->
                    chord_rpc:call(Socket, get, [Key, Consistency]);
                {get, Key} ->
                    chord_rpc:call(Socket, get, [Key]);
                {delete, Key} ->
                    chord_rpc:call(Socket, delete, [Key])
            end,
            chord_rpc:close(Socket),
            Result;
        Error -> Error
    end.

find_successor_on_remote_node(#node_info{ip = IP, port = Port}, Key) ->
    case chord_rpc:connect(inet:ntoa(IP), Port) of
        {ok, Socket} ->
            Result = chord_rpc:call(Socket, find_successor, [Key]),
            chord_rpc:close(Socket),
            case Result of
                {ok, NodeInfo} -> {ok, decode_node_info(NodeInfo)};
                Error -> Error
            end;
        Error -> Error
    end.

transfer_keys_from_successor(#chord_state{self = Self, kvs_store = Store} = _State, Successor) ->
    %% Request keys that should belong to us from our successor
    case Successor#node_info.pid of
        Pid when is_pid(Pid) ->
            %% Local node
            KeyValuePairs = gen_server:call(Pid, {transfer_keys, Self, range}),
            lists:foreach(fun({Key, Value}) ->
                kvs_store:put(Store, Key, Value)
            end, KeyValuePairs);
        _ ->
            %% Remote node - request key transfer via RPC
            case chord_rpc:connect(inet:ntoa(Successor#node_info.ip), Successor#node_info.port) of
                {ok, Socket} ->
                    case chord_rpc:call(Socket, transfer_keys, [Self#node_info.id]) of
                        {ok, KeyValuePairs} ->
                            lists:foreach(fun({Key, Value}) ->
                                kvs_store:put(Store, Key, Value)
                            end, KeyValuePairs);
                        _ -> ok
                    end,
                    chord_rpc:close(Socket);
                _ -> ok
            end
    end.

transfer_keys_to_node(#node_info{pid = Pid}, KeyValuePairs) when is_pid(Pid) ->
    gen_server:call(Pid, {receive_keys, KeyValuePairs});
transfer_keys_to_node(#node_info{ip = IP, port = Port}, KeyValuePairs) ->
    case chord_rpc:connect(inet:ntoa(IP), Port) of
        {ok, Socket} ->
            chord_rpc:call(Socket, receive_keys, [KeyValuePairs]),
            chord_rpc:close(Socket);
        _ -> ok
    end.

update_successor_on_node(#node_info{pid = Pid}, NewSucc) when is_pid(Pid) ->
    gen_server:call(Pid, {update_successor, NewSucc});
update_successor_on_node(#node_info{ip = IP, port = Port}, NewSucc) ->
    case chord_rpc:connect(inet:ntoa(IP), Port) of
        {ok, Socket} ->
            SuccInfo = encode_node_info(NewSucc),
            chord_rpc:call(Socket, update_successor, [SuccInfo]),
            chord_rpc:close(Socket);
        _ -> ok
    end.

update_predecessor_on_node(#node_info{pid = Pid}, NewPred) when is_pid(Pid) ->
    gen_server:call(Pid, {update_predecessor, NewPred});
update_predecessor_on_node(#node_info{ip = IP, port = Port}, NewPred) ->
    case chord_rpc:connect(inet:ntoa(IP), Port) of
        {ok, Socket} ->
            PredInfo = case NewPred of
                undefined -> undefined;
                _ -> encode_node_info(NewPred)
            end,
            chord_rpc:call(Socket, update_predecessor, [PredInfo]),
            chord_rpc:close(Socket);
        _ -> ok
    end.

collect_ring_nodes(#chord_state{self = Self, successor = Succ}) ->
    collect_ring_nodes(Self, Succ, [Self]).

transfer_keys_to_new_predecessor(Store, _OldPred, NewPred, Self) ->
    % Transfer keys that now belong to the new predecessor
    {ok, AllKeys} = kvs_store:list_keys(Store),
    KeysToTransfer = lists:filter(fun(Key) ->
        KeyHash = hash_key(Key),
        % Check if this key now belongs to the new predecessor
        case NewPred of
            undefined -> false;
            _ ->
                % Key belongs to new predecessor if it's between (NewPred, Self]
                not key_belongs_to(KeyHash, NewPred#node_info.id, Self#node_info.id)
        end
    end, AllKeys),
    
    % Transfer the keys to the new predecessor
    case KeysToTransfer of
        [] -> ok;
        _ ->
            KeyValuePairs = lists:map(fun(Key) ->
                {ok, Value} = kvs_store:get(Store, Key),
                % Delete from our store since it's no longer our responsibility
                kvs_store:delete(Store, Key),
                {Key, Value}
            end, KeysToTransfer),
            transfer_keys_to_node(NewPred, KeyValuePairs)
    end.

find_primary_node(KeyHash, Self, Pred, _SuccList) ->
    % Find which node is the primary for a given key hash
    case Pred of
        undefined -> Self;  % Single node ring
        _ ->
            % Check if the key belongs to us
            case key_belongs_to(KeyHash, Pred#node_info.id, Self#node_info.id) of
                true -> Self;
                false ->
                    % Key doesn't belong to us, it must belong to a successor
                    % For simplicity, return undefined (will be cleaned up)
                    undefined
            end
    end.

get_replica_set(PrimaryNode, SuccList) ->
    % Get the set of nodes that should hold replicas for a primary node
    case PrimaryNode of
        undefined -> [];
        _ ->
            % The replica set is the primary node plus its successors
            ReplicaNodes = lists:sublist(SuccList, ?REPLICATION_FACTOR - 1),
            [PrimaryNode | ReplicaNodes]
    end.

collect_ring_nodes(Start, Current, Acc) when Current#node_info.id =:= Start#node_info.id ->
    Acc;
collect_ring_nodes(Start, Current, Acc) ->
    case lists:member(Current, Acc) of
        true -> Acc;  %% Avoid infinite loop
        false ->
            %% Get successor of current node
            NextSucc = case Current#node_info.pid of
                Pid when is_pid(Pid) ->
                    gen_server:call(Pid, get_successor);
                _ ->
                    %% Remote node
                    case chord_rpc:connect(inet:ntoa(Current#node_info.ip), Current#node_info.port) of
                        {ok, Socket} ->
                            case chord_rpc:call(Socket, get_successor, []) of
                                {ok, SuccInfo} ->
                                    chord_rpc:close(Socket),
                                    decode_node_info(SuccInfo);
                                _ ->
                                    chord_rpc:close(Socket),
                                    Start
                            end;
                        _ -> Start
                    end
            end,
            collect_ring_nodes(Start, NextSucc, [Current | Acc])
    end.