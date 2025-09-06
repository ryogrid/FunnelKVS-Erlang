-module(chord).
-behaviour(gen_server).

-include("../include/chord.hrl").

%% API
-export([start_link/1, start_link/2, stop/1]).
-export([hash/1, generate_node_id/2]).
-export([key_belongs_to/3, between/3]).
-export([init_finger_table/1, find_successor/2]).
-export([get_id/1, get_successor/1, get_predecessor/1, get_finger_table/1, get_successor_list/1]).
-export([put/3, get/2, delete/2]).
-export([closest_preceding_node/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% Internal exports for RPC
-export([handle_find_successor/2, handle_get_predecessor/1, handle_notify/2]).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Port) ->
    gen_server:start_link(?MODULE, [Port, undefined], []).

start_link(Port, {JoinIP, JoinPort}) ->
    gen_server:start_link(?MODULE, [Port, {JoinIP, JoinPort}], []).

stop(Pid) ->
    gen_server:stop(Pid).

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

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Port, JoinNode]) ->
    % Start KVS store for this node
    {ok, KvsStore} = kvs_store:start_link(),
    
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
            join_ring(State2, JoinIP, JoinPort)
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
            {error, not_implemented} % TODO: Implement RPC
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
            {error, not_implemented} % TODO: Implement RPC
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
            {error, not_implemented} % TODO: Implement RPC
    end,
    {reply, Result, State};

handle_call({get_predecessor_rpc}, _From, #chord_state{predecessor = Pred} = State) ->
    {reply, Pred, State};

handle_call({notify_rpc, Node}, _From, State) ->
    NewState = handle_notify_internal(Node, State),
    {reply, ok, NewState};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(stabilize, State) ->
    NewState = stabilize(State),
    {noreply, NewState};

handle_info(fix_fingers, State) ->
    NewState = fix_fingers(State),
    {noreply, NewState};

handle_info(check_predecessor, State) ->
    NewState = check_predecessor(State),
    {noreply, NewState};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #chord_state{kvs_store = Store} = State) ->
    stop_maintenance_timers(State),
    kvs_store:stop(Store),
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

join_ring(State, JoinIP, JoinPort) ->
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

stabilize(#chord_state{self = Self, successor = Successor} = State) ->
    % Reschedule timer
    erlang:send_after(?STABILIZE_INTERVAL, self(), stabilize),
    
    % In single-node ring, successor is self - skip RPC
    case Successor#node_info.id =:= Self#node_info.id of
        true ->
            State;  % Nothing to do in single-node ring
        false ->
            % Check if successor's predecessor is between us and successor
            case get_predecessor_rpc(Successor) of
                {ok, Pred} when Pred =/= undefined ->
                    case between(Pred#node_info.id, Self#node_info.id, Successor#node_info.id) of
                        true ->
                            % Update our successor
                            State2 = State#chord_state{successor = Pred},
                            % Notify the new successor
                            notify_rpc(Pred, Self),
                            State2;
                        false ->
                            % Notify our successor
                            notify_rpc(Successor, Self),
                            State
                    end;
                _ ->
                    % Notify our successor anyway
                    notify_rpc(Successor, Self),
                    State
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
                            % TODO: Implement RPC to find successor on remote node
                            Successor
                    end
            end
    end.

handle_notify_internal(Node, #chord_state{self = Self, predecessor = Pred} = State) ->
    case Pred of
        undefined ->
            State#chord_state{predecessor = Node};
        _ ->
            case between(Node#node_info.id, Pred#node_info.id, Self#node_info.id) of
                true ->
                    State#chord_state{predecessor = Node};
                false ->
                    State
            end
    end.

get_predecessor_rpc(#node_info{pid = Pid}) when Pid =:= self() ->
    {error, self_reference};
get_predecessor_rpc(#node_info{pid = Pid}) when is_pid(Pid) ->
    gen_server:call(Pid, {get_predecessor_rpc});
get_predecessor_rpc(_) ->
    {error, not_implemented}.

notify_rpc(#node_info{pid = Pid}, Node) when is_pid(Pid) ->
    gen_server:call(Pid, {notify_rpc, Node});
notify_rpc(_, _) ->
    {error, not_implemented}.

is_alive(#node_info{pid = Pid}) when is_pid(Pid) ->
    erlang:is_process_alive(Pid);
is_alive(_) ->
    % TODO: Implement ping for remote nodes
    true.

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

%% RPC handlers
handle_find_successor(Key, State) ->
    find_successor_internal(Key, State).

handle_get_predecessor(#chord_state{predecessor = Pred}) ->
    Pred.

handle_notify(Node, State) ->
    handle_notify_internal(Node, State).