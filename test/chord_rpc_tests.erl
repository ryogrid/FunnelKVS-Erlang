-module(chord_rpc_tests).
-include_lib("eunit/include/eunit.hrl").
-include("../include/chord.hrl").

%% Test RPC server startup
rpc_server_start_test() ->
    % Start RPC server on a port
    {ok, Pid} = chord_rpc:start_server(9501),
    ?assert(is_process_alive(Pid)),
    
    % Should be able to stop it
    ok = chord_rpc:stop_server(Pid),
    timer:sleep(100),
    ?assertNot(is_process_alive(Pid)).

%% Test RPC client connection
rpc_client_connect_test() ->
    % Start server
    {ok, ServerPid} = chord_rpc:start_server(9502),
    timer:sleep(100),
    
    % Connect client
    {ok, Socket} = chord_rpc:connect("127.0.0.1", 9502),
    ?assert(is_port(Socket)),
    
    % Disconnect
    ok = chord_rpc:disconnect(Socket),
    
    % Stop server
    chord_rpc:stop_server(ServerPid).

%% Test find_successor RPC
find_successor_rpc_test() ->
    % Start two Chord nodes
    {ok, Node1} = chord:start_link(9601),
    {ok, Node2} = chord:start_link(9602),
    timer:sleep(100),
    
    % Start RPC servers for both nodes
    {ok, Rpc1} = chord_rpc:start_server(9603, Node1),
    {ok, Rpc2} = chord_rpc:start_server(9604, Node2),
    timer:sleep(100),
    
    % Connect to Node1's RPC server
    {ok, Socket} = chord_rpc:connect("127.0.0.1", 9603),
    
    % Call find_successor via RPC
    TestKey = 12345,
    {ok, Successor} = chord_rpc:call(Socket, find_successor, TestKey),
    ?assert(is_record(Successor, node_info)),
    
    % Clean up
    chord_rpc:disconnect(Socket),
    chord_rpc:stop_server(Rpc1),
    chord_rpc:stop_server(Rpc2),
    chord:stop(Node1),
    chord:stop(Node2).

%% Test get_predecessor RPC
get_predecessor_rpc_test() ->
    % Start a Chord node
    {ok, Node1} = chord:start_link(9701),
    timer:sleep(100),
    
    % Start RPC server
    {ok, RpcPid} = chord_rpc:start_server(9702, Node1),
    timer:sleep(100),
    
    % Connect and call get_predecessor
    {ok, Socket} = chord_rpc:connect("127.0.0.1", 9702),
    {ok, Pred} = chord_rpc:call(Socket, get_predecessor, []),
    
    % Initially should be undefined
    ?assertEqual(undefined, Pred),
    
    % Clean up
    chord_rpc:disconnect(Socket),
    chord_rpc:stop_server(RpcPid),
    chord:stop(Node1).

%% Test notify RPC
notify_rpc_test() ->
    % Start a Chord node
    {ok, Node1} = chord:start_link(9801),
    timer:sleep(100),
    
    % Start RPC server
    {ok, RpcPid} = chord_rpc:start_server(9802, Node1),
    timer:sleep(100),
    
    % Create a node_info record
    NotifyingNode = #node_info{
        id = 999999,
        ip = {127, 0, 0, 1},
        port = 9999,
        pid = undefined
    },
    
    % Connect and call notify
    {ok, Socket} = chord_rpc:connect("127.0.0.1", 9802),
    {ok, ok} = chord_rpc:call(Socket, notify, NotifyingNode),
    
    % Check that predecessor was updated
    {ok, Pred} = chord_rpc:call(Socket, get_predecessor, []),
    ?assertEqual(NotifyingNode#node_info.id, Pred#node_info.id),
    
    % Clean up
    chord_rpc:disconnect(Socket),
    chord_rpc:stop_server(RpcPid),
    chord:stop(Node1).

%% Test get_successor_list RPC
get_successor_list_rpc_test() ->
    % Start a Chord node
    {ok, Node1} = chord:start_link(9901),
    timer:sleep(100),
    
    % Start RPC server
    {ok, RpcPid} = chord_rpc:start_server(9902, Node1),
    timer:sleep(100),
    
    % Connect and call get_successor_list
    {ok, Socket} = chord_rpc:connect("127.0.0.1", 9902),
    {ok, SuccList} = chord_rpc:call(Socket, get_successor_list, []),
    
    ?assert(is_list(SuccList)),
    
    % Clean up
    chord_rpc:disconnect(Socket),
    chord_rpc:stop_server(RpcPid),
    chord:stop(Node1).

%% Test transfer_keys RPC
transfer_keys_rpc_test() ->
    % Start two Chord nodes
    {ok, Node1} = chord:start_link(10001),
    {ok, Node2} = chord:start_link(10002),
    timer:sleep(100),
    
    % Add some keys to Node1
    chord:put(Node1, <<"key1">>, <<"value1">>),
    chord:put(Node1, <<"key2">>, <<"value2">>),
    chord:put(Node1, <<"key3">>, <<"value3">>),
    
    % Start RPC servers
    {ok, Rpc1} = chord_rpc:start_server(10003, Node1),
    {ok, Rpc2} = chord_rpc:start_server(10004, Node2),
    timer:sleep(100),
    
    % Connect to Node1
    {ok, Socket} = chord_rpc:connect("127.0.0.1", 10003),
    
    % Get Node2's info
    Node2Info = #node_info{
        id = chord:get_id(Node2),
        ip = {127, 0, 0, 1},
        port = 10004,
        pid = Node2
    },
    
    % Request key transfer for keys that should belong to Node2
    {ok, TransferredKeys} = chord_rpc:call(Socket, transfer_keys, {Node2Info, range}),
    ?assert(is_list(TransferredKeys)),
    
    % Clean up
    chord_rpc:disconnect(Socket),
    chord_rpc:stop_server(Rpc1),
    chord_rpc:stop_server(Rpc2),
    chord:stop(Node1),
    chord:stop(Node2).

%% Test multiple concurrent RPC calls
concurrent_rpc_test() ->
    % Start a Chord node
    {ok, Node1} = chord:start_link(10101),
    timer:sleep(100),
    
    % Start RPC server
    {ok, RpcPid} = chord_rpc:start_server(10102, Node1),
    timer:sleep(100),
    
    % Spawn multiple concurrent RPC clients
    Parent = self(),
    NumClients = 10,
    
    Pids = [spawn(fun() ->
        {ok, Socket} = chord_rpc:connect("127.0.0.1", 10102),
        
        % Make multiple RPC calls
        {ok, _} = chord_rpc:call(Socket, get_predecessor, []),
        {ok, _} = chord_rpc:call(Socket, get_successor_list, []),
        TestKey = I * 1000,
        {ok, _} = chord_rpc:call(Socket, find_successor, TestKey),
        
        chord_rpc:disconnect(Socket),
        Parent ! {done, I}
    end) || I <- lists:seq(1, NumClients)],
    
    % Wait for all clients to complete
    lists:foreach(fun(_) ->
        receive {done, _} -> ok
        after 5000 -> ?assert(false)
        end
    end, Pids),
    
    % Clean up
    chord_rpc:stop_server(RpcPid),
    chord:stop(Node1).

%% Test RPC error handling
rpc_error_handling_test() ->
    % Try to connect to non-existent server
    Result = chord_rpc:connect("127.0.0.1", 19999),
    ?assertMatch({error, _}, Result),
    
    % Start server and stop it
    {ok, ServerPid} = chord_rpc:start_server(10201),
    timer:sleep(100),
    {ok, Socket} = chord_rpc:connect("127.0.0.1", 10201),
    chord_rpc:stop_server(ServerPid),
    timer:sleep(100),
    
    % Try to make RPC call on closed connection
    Result2 = chord_rpc:call(Socket, get_predecessor, []),
    ?assertMatch({error, _}, Result2).

%% Test RPC with binary data
rpc_binary_data_test() ->
    % Start a Chord node
    {ok, Node1} = chord:start_link(10301),
    timer:sleep(100),
    
    % Start RPC server
    {ok, RpcPid} = chord_rpc:start_server(10302, Node1),
    timer:sleep(100),
    
    % Connect
    {ok, Socket} = chord_rpc:connect("127.0.0.1", 10302),
    
    % Store binary data via local call first
    BinaryKey = <<255, 254, 253, 252>>,
    BinaryValue = <<0, 1, 2, 3, 4, 5>>,
    chord:put(Node1, BinaryKey, BinaryValue),
    
    % Retrieve via RPC
    {ok, {Key, Value}} = chord_rpc:call(Socket, get_key_value, BinaryKey),
    ?assertEqual(BinaryKey, Key),
    ?assertEqual(BinaryValue, Value),
    
    % Clean up
    chord_rpc:disconnect(Socket),
    chord_rpc:stop_server(RpcPid),
    chord:stop(Node1).