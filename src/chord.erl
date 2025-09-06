-module(chord).
-behaviour(gen_server).

-include("../include/chord.hrl").

%% API
-export([start_link/1, start_link/2, stop/1]).
-export([start_node/2, stop_node/1, create_ring/1, join_ring/3, leave_ring/1]).
-export([hash/1, generate_node_id/2]).
-export([key_belongs_to/3, between/3]).
-export([init_finger_table/1, find_successor/2]).
-export([get_id/1, get_successor/1, get_predecessor/1, get_finger_table/1, get_successor_list/1]).
-export([put/3, get/2, delete/2]).
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

start_link(Port, {JoinIP, JoinPort}) ->
    gen_server:start_link(?MODULE, [Port, {JoinIP, JoinPort}], []).

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
    gen_server:call(Pid, {join_ring, Host, Port}, 10000).

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

put(Pid, Key, Value) ->
    gen_server:call(Pid, {put, Key, Value}).

get(Pid, Key) ->
    gen_server:call(Pid, {get, Key}).

delete(Pid, Key) ->
    gen_server:call(Pid, {delete, Key}).

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

init([Port, JoinNode]) ->
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
    
    % Join existing ring if specified
    State3 = case JoinNode of
        undefined ->
            % Creating new ring, we are our own successor
            State2;
        {JoinIP, JoinPort} ->
            join_ring_internal(State2, JoinIP, JoinPort)
    end,
    
    {ok, State3}.

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

handle_call({put, Key, Value}, _From, #chord_state{kvs_store = Store} = State) ->
    KeyHash = hash_key(Key),
    ResponsibleNode = find_successor_internal(KeyHash, State),
    
    Result = case ResponsibleNode#node_info.pid of
        Pid when Pid =:= self() ->
            % We are responsible for this key
            kvs_store:put(Store, Key, Value);
        _ ->
            % Forward to responsible node
            forward_to_remote_node(ResponsibleNode, {put, Key, Value})
    end,
    {reply, Result, State};

handle_call({get, Key}, _From, #chord_state{kvs_store = Store} = State) ->
    KeyHash = hash_key(Key),
    ResponsibleNode = find_successor_internal(KeyHash, State),
    
    Result = case ResponsibleNode#node_info.pid of
        Pid when Pid =:= self() ->
            % We are responsible for this key
            kvs_store:get(Store, Key);
        _ ->
            % Forward to responsible node
            forward_to_remote_node(ResponsibleNode, {get, Key})
    end,
    {reply, Result, State};

handle_call({delete, Key}, _From, #chord_state{kvs_store = Store} = State) ->
    KeyHash = hash_key(Key),
    ResponsibleNode = find_successor_internal(KeyHash, State),
    
    Result = case ResponsibleNode#node_info.pid of
        Pid when Pid =:= self() ->
            % We are responsible for this key
            kvs_store:delete(Store, Key);
        _ ->
            % Forward to responsible node
            forward_to_remote_node(ResponsibleNode, {delete, Key})
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
    {noreply, State#chord_state{successor = NewSucc}};

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

join_ring_internal(State, JoinIP, JoinPort) ->
    % Find our successor through the existing node
    JoinNode = #node_info{
        id = generate_node_id(JoinIP, JoinPort),
        ip = parse_ip(JoinIP),
        port = JoinPort,
        pid = undefined  % Remote node
    },
    
    % For now, just set the join node as our successor
    % TODO: Implement proper RPC to find successor
    State#chord_state{successor = JoinNode}.

do_stabilize_async(NodePid, #chord_state{self = Self, successor = Successor, predecessor = Pred}) ->
    % Special case: if we have no predecessor and successor is self,
    % check if there's a new node between us
    case Successor#node_info.id =:= Self#node_info.id andalso Pred =/= undefined of
        true ->
            % Someone joined, make them our successor
            gen_server:cast(NodePid, {update_successor, Pred});
        false when Successor#node_info.id =:= Self#node_info.id ->
            ok;  % Still alone in the ring
        false ->
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
                            notify_rpc(Successor, Self)
                    end;
                _ ->
                    % Notify our successor anyway
                    notify_rpc(Successor, Self)
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
    UpdatedFingerTable = lists:keyreplace(
        NextFinger, 
        #finger_entry.start,
        FingerTable,
        UpdatedFinger
    ),
    
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
                    % Predecessor has failed
                    State#chord_state{predecessor = undefined}
            end
    end.

find_successor_internal(Key, #chord_state{
    self = Self,
    successor = Successor,
    finger_table = FingerTable
} = _State) ->
    % In single-node ring, we handle all keys
    case Successor#node_info.id =:= Self#node_info.id of
        true ->
            Self;  % Return self as successor in single-node ring
        false ->
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
    end.

handle_notify_internal(Node, #chord_state{self = Self, predecessor = Pred, successor = Succ} = State) ->
    %% Update predecessor if needed
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
    
    %% If we are our own successor (single node ring) and a new node is notifying us,
    %% it should become our successor (for initial ring formation)
    State3 = case Succ#node_info.id =:= Self#node_info.id andalso Node#node_info.id =/= Self#node_info.id of
        true ->
            %% In a single-node ring that gets a notify, the new node should become our successor
            %% Schedule a reciprocal notify after a short delay
            erlang:send_after(100, self(), {notify_new_successor, Node}),
            State2#chord_state{successor = Node};
        false ->
            State2
    end,
    State3.

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
handle_rpc_request(notify, [NodeInfo], State) ->
    Node = decode_node_info(NodeInfo),
    NewState = handle_notify_internal(Node, State),
    {ok, ok, NewState};
handle_rpc_request(put, [Key, Value], #chord_state{kvs_store = Store} = State) ->
    KeyHash = hash_key(Key),
    ResponsibleNode = find_successor_internal(KeyHash, State),
    case ResponsibleNode#node_info.pid of
        Pid when Pid =:= self() ->
            kvs_store:put(Store, Key, Value);
        _ ->
            forward_to_remote_node(ResponsibleNode, {put, Key, Value})
    end;
handle_rpc_request(get, [Key], #chord_state{kvs_store = Store} = State) ->
    KeyHash = hash_key(Key),
    ResponsibleNode = find_successor_internal(KeyHash, State),
    case ResponsibleNode#node_info.pid of
        Pid when Pid =:= self() ->
            kvs_store:get(Store, Key);
        _ ->
            forward_to_remote_node(ResponsibleNode, {get, Key})
    end;
handle_rpc_request(delete, [Key], #chord_state{kvs_store = Store} = State) ->
    KeyHash = hash_key(Key),
    ResponsibleNode = find_successor_internal(KeyHash, State),
    case ResponsibleNode#node_info.pid of
        Pid when Pid =:= self() ->
            kvs_store:delete(Store, Key);
        _ ->
            forward_to_remote_node(ResponsibleNode, {delete, Key})
    end;
handle_rpc_request(transfer_keys, [NodeId], #chord_state{kvs_store = Store, self = Self}) ->
    {ok, AllKeys} = kvs_store:list_keys(Store),
    TransferredKeys = lists:filter(fun(Key) ->
        KeyHash = hash_key(Key),
        should_transfer_key(KeyHash, Self#node_info.id, NodeId)
    end, AllKeys),
    KeyValuePairs = lists:map(fun(Key) ->
        {ok, Value} = kvs_store:get(Store, Key),
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
                {put, Key, Value} ->
                    chord_rpc:call(Socket, put, [Key, Value]);
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