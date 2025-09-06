-module(kvs_store_tests).
-include_lib("eunit/include/eunit.hrl").

%% Test fixture setup and teardown
setup() ->
    {ok, Pid} = kvs_store:start_link(),
    Pid.

teardown(Pid) ->
    kvs_store:stop(Pid).

%% Test wrapper with setup/teardown
kvs_store_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [
      fun test_put_and_get/1,
      fun test_get_nonexistent/1,
      fun test_delete/1,
      fun test_update_existing/1,
      fun test_multiple_keys/1,
      fun test_binary_keys_values/1,
      fun test_large_values/1,
      fun test_concurrent_operations/1
     ]}.

%% Individual test cases
test_put_and_get(Pid) ->
    fun() ->
        Key = <<"key1">>,
        Value = <<"value1">>,
        ?assertEqual(ok, kvs_store:put(Pid, Key, Value)),
        ?assertEqual({ok, Value}, kvs_store:get(Pid, Key))
    end.

test_get_nonexistent(Pid) ->
    fun() ->
        Key = <<"nonexistent">>,
        ?assertEqual({error, not_found}, kvs_store:get(Pid, Key))
    end.

test_delete(Pid) ->
    fun() ->
        Key = <<"key_to_delete">>,
        Value = <<"value">>,
        ?assertEqual(ok, kvs_store:put(Pid, Key, Value)),
        ?assertEqual({ok, Value}, kvs_store:get(Pid, Key)),
        ?assertEqual(ok, kvs_store:delete(Pid, Key)),
        ?assertEqual({error, not_found}, kvs_store:get(Pid, Key))
    end.

test_update_existing(Pid) ->
    fun() ->
        Key = <<"key_update">>,
        Value1 = <<"value1">>,
        Value2 = <<"value2">>,
        ?assertEqual(ok, kvs_store:put(Pid, Key, Value1)),
        ?assertEqual({ok, Value1}, kvs_store:get(Pid, Key)),
        ?assertEqual(ok, kvs_store:put(Pid, Key, Value2)),
        ?assertEqual({ok, Value2}, kvs_store:get(Pid, Key))
    end.

test_multiple_keys(Pid) ->
    fun() ->
        Keys = [<<"key", (integer_to_binary(I))/binary>> || I <- lists:seq(1, 100)],
        Values = [<<"value", (integer_to_binary(I))/binary>> || I <- lists:seq(1, 100)],
        
        % Put all key-value pairs
        lists:foreach(fun({K, V}) ->
            ?assertEqual(ok, kvs_store:put(Pid, K, V))
        end, lists:zip(Keys, Values)),
        
        % Verify all can be retrieved
        lists:foreach(fun({K, V}) ->
            ?assertEqual({ok, V}, kvs_store:get(Pid, K))
        end, lists:zip(Keys, Values))
    end.

test_binary_keys_values(Pid) ->
    fun() ->
        % Test with various binary data including special characters
        Key = <<0, 1, 2, 255, 254, 253>>,
        Value = <<"\r\n\t", 0, 255>>,
        ?assertEqual(ok, kvs_store:put(Pid, Key, Value)),
        ?assertEqual({ok, Value}, kvs_store:get(Pid, Key))
    end.

test_large_values(Pid) ->
    fun() ->
        Key = <<"large_key">>,
        % Create a 1MB value
        Value = binary:copy(<<"x">>, 1024 * 1024),
        ?assertEqual(ok, kvs_store:put(Pid, Key, Value)),
        {ok, Retrieved} = kvs_store:get(Pid, Key),
        ?assertEqual(byte_size(Value), byte_size(Retrieved)),
        ?assertEqual(Value, Retrieved)
    end.

test_concurrent_operations(Pid) ->
    fun() ->
        NumProcesses = 100,
        NumOps = 10,
        
        % Spawn concurrent processes doing puts
        Parent = self(),
        Pids = [spawn(fun() ->
            lists:foreach(fun(J) ->
                K = <<"proc", (integer_to_binary(I))/binary, "_", (integer_to_binary(J))/binary>>,
                V = <<"value", (integer_to_binary(I))/binary, "_", (integer_to_binary(J))/binary>>,
                kvs_store:put(Pid, K, V)
            end, lists:seq(1, NumOps)),
            Parent ! {done, self()}
        end) || I <- lists:seq(1, NumProcesses)],
        
        % Wait for all processes to complete
        lists:foreach(fun(P) ->
            receive {done, P} -> ok end
        end, Pids),
        
        % Verify all values are stored correctly
        lists:foreach(fun(I) ->
            lists:foreach(fun(J) ->
                K = <<"proc", (integer_to_binary(I))/binary, "_", (integer_to_binary(J))/binary>>,
                V = <<"value", (integer_to_binary(I))/binary, "_", (integer_to_binary(J))/binary>>,
                ?assertEqual({ok, V}, kvs_store:get(Pid, K))
            end, lists:seq(1, NumOps))
        end, lists:seq(1, NumProcesses))
    end.

%% Additional unit tests for edge cases
empty_key_test() ->
    {ok, Pid} = kvs_store:start_link(),
    ?assertEqual(ok, kvs_store:put(Pid, <<>>, <<"value">>)),
    ?assertEqual({ok, <<"value">>}, kvs_store:get(Pid, <<>>)),
    kvs_store:stop(Pid).

empty_value_test() ->
    {ok, Pid} = kvs_store:start_link(),
    ?assertEqual(ok, kvs_store:put(Pid, <<"key">>, <<>>)),
    ?assertEqual({ok, <<>>}, kvs_store:get(Pid, <<"key">>)),
    kvs_store:stop(Pid).

%% Test for statistics/monitoring
stats_test() ->
    {ok, Pid} = kvs_store:start_link(),
    
    % Initial stats should be empty
    ?assertEqual({ok, 0}, kvs_store:size(Pid)),
    
    % Add some keys
    kvs_store:put(Pid, <<"k1">>, <<"v1">>),
    kvs_store:put(Pid, <<"k2">>, <<"v2">>),
    kvs_store:put(Pid, <<"k3">>, <<"v3">>),
    
    ?assertEqual({ok, 3}, kvs_store:size(Pid)),
    
    % Delete one
    kvs_store:delete(Pid, <<"k2">>),
    ?assertEqual({ok, 2}, kvs_store:size(Pid)),
    
    % Clear all
    ?assertEqual(ok, kvs_store:clear(Pid)),
    ?assertEqual({ok, 0}, kvs_store:size(Pid)),
    
    kvs_store:stop(Pid).

%% Test list_keys functionality
list_keys_test() ->
    {ok, Pid} = kvs_store:start_link(),
    
    Keys = [<<"a">>, <<"b">>, <<"c">>, <<"d">>],
    lists:foreach(fun(K) ->
        kvs_store:put(Pid, K, <<"value">>)
    end, Keys),
    
    {ok, StoredKeys} = kvs_store:list_keys(Pid),
    ?assertEqual(lists:sort(Keys), lists:sort(StoredKeys)),
    
    kvs_store:stop(Pid).