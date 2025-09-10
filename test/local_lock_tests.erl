-module(local_lock_tests).
-include_lib("eunit/include/eunit.hrl").

%% Test basic lock acquisition and release
basic_acquire_release_test() ->
    ?assertEqual(false, local_lock:held()),
    ?assertEqual(ok, local_lock:acquire()),
    ?assertEqual(true, local_lock:held()),
    ?assertEqual(ok, local_lock:release()),
    ?assertEqual(false, local_lock:held()).

%% Test named lock variants work the same
named_lock_test() ->
    ?assertEqual(false, local_lock:held()),
    ?assertEqual(ok, local_lock:acquire(test_lock)),
    ?assertEqual(true, local_lock:held()),
    ?assertEqual(ok, local_lock:release(test_lock)),
    ?assertEqual(false, local_lock:held()).

%% Test single lock principle - can't acquire when already holding
single_lock_principle_test() ->
    ?assertEqual(ok, local_lock:acquire()),
    ?assertEqual({error, already_holding_lock}, local_lock:acquire()),
    ?assertEqual({error, already_holding_lock}, local_lock:acquire(another_lock)),
    ?assertEqual(ok, local_lock:release()),
    ?assertEqual(ok, local_lock:acquire()), % Now we can acquire again
    ?assertEqual(ok, local_lock:release()).

%% Test releasing without holding
release_without_holding_test() ->
    ?assertEqual({error, not_held}, local_lock:release()),
    ?assertEqual({error, not_held}, local_lock:release(test_lock)).

%% Test per-process isolation - different processes can hold locks independently
per_process_isolation_test() ->
    Parent = self(),
    ?assertEqual(ok, local_lock:acquire()),
    
    % Spawn a child process that can acquire its own lock
    Pid = spawn(fun() ->
        ?assertEqual(false, local_lock:held()),
        ?assertEqual(ok, local_lock:acquire()),
        ?assertEqual(true, local_lock:held()),
        Parent ! {child_acquired, self()},
        receive
            release -> ok
        end,
        ?assertEqual(ok, local_lock:release()),
        Parent ! {child_released, self()}
    end),
    
    receive {child_acquired, Pid} -> ok end,
    
    % Parent still holds its lock
    ?assertEqual(true, local_lock:held()),
    
    % Tell child to release
    Pid ! release,
    receive {child_released, Pid} -> ok end,
    
    % Parent still holds its lock
    ?assertEqual(true, local_lock:held()),
    ?assertEqual(ok, local_lock:release()).