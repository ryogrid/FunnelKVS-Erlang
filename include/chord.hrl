-ifndef(CHORD_HRL).
-define(CHORD_HRL, true).

%% Chord protocol constants
-define(M, 160).  % SHA-1 produces 160-bit hash
-define(FINGER_TABLE_SIZE, 160).
-define(SUCCESSOR_LIST_SIZE, 3).
-define(STABILIZE_INTERVAL, 1000).  % milliseconds
-define(FIX_FINGERS_INTERVAL, 1000).  % milliseconds
-define(CHECK_PREDECESSOR_INTERVAL, 2000).  % milliseconds
-define(REPLICATE_INTERVAL, 5000).  % milliseconds

%% Node information record
-record(node_info, {
    id :: integer(),                % Node ID (SHA-1 hash as integer)
    ip :: inet:ip_address(),        % IP address
    port :: inet:port_number(),     % Port number
    pid :: pid() | undefined        % Process ID for local nodes
}).

%% Finger table entry
-record(finger_entry, {
    start :: integer(),                          % Start of finger interval
    interval :: {integer(), integer()},         % [start, start + 2^(i-1))
    node :: #node_info{} | undefined            % Successor node for this interval
}).

%% Chord node state
-record(chord_state, {
    self :: #node_info{},                       % This node's info
    predecessor :: #node_info{} | undefined,    % Predecessor node
    successor :: #node_info{} | undefined,      % Immediate successor
    finger_table :: [#finger_entry{}],         % Finger table entries
    successor_list :: [#node_info{}],          % List of successors for fault tolerance
    next_finger :: integer(),                   % Next finger to fix
    kvs_store :: pid(),                        % KVS store process
    stabilize_timer :: reference() | undefined, % Stabilization timer
    fix_fingers_timer :: reference() | undefined, % Fix fingers timer
    check_pred_timer :: reference() | undefined  % Check predecessor timer
}).

%% Chord RPC message types
-record(chord_msg, {
    type :: atom(),
    from :: #node_info{},
    to :: #node_info{},
    payload :: any()
}).

-endif.