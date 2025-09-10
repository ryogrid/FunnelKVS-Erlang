%% @doc Tests for local_lock module
-module(local_lock_tests).
-include_lib("eunit/include/eunit.hrl").

%% Test basic acquire/release functionality
acquire_release_test() ->
    %% Initially no lock held
    ?assertEqual(false, local_lock:held()),
    
    %% Acquire lock
    ?assertEqual(ok, local_lock:acquire()),
    ?assertEqual(true, local_lock:held()),
    
    %% Cannot acquire again
    ?assertEqual({error, already_holding_lock}, local_lock:acquire()),
    ?assertEqual(true, local_lock:held()),
    
    %% Release lock
    ?assertEqual(ok, local_lock:release()),
    ?assertEqual(false, local_lock:held()),
    
    %% Cannot release when not held
    ?assertEqual({error, not_held}, local_lock:release()).

%% Test named acquire/release
named_acquire_test() ->
    %% Test named acquire (name is only for logging)
    ?assertEqual(ok, local_lock:acquire(test_lock)),
    ?assertEqual(true, local_lock:held()),
    ?assertEqual({error, already_holding_lock}, local_lock:acquire(another_lock)),
    ?assertEqual(ok, local_lock:release(test_lock)),
    ?assertEqual(false, local_lock:held()).

%% Test different processes have independent locks
process_independence_test() ->
    Parent = self(),
    
    %% Acquire lock in parent
    ?assertEqual(ok, local_lock:acquire()),
    
    %% Spawn child process
    Pid = spawn(fun() ->
        %% Child should be able to acquire its own lock
        Result1 = local_lock:acquire(),
        Result2 = local_lock:held(),
        Result3 = local_lock:release(),
        Parent ! {self(), {Result1, Result2, Result3}}
    end),
    
    %% Wait for child result
    receive
        {Pid, {Result1, Result2, Result3}} ->
            ?assertEqual(ok, Result1),
            ?assertEqual(true, Result2),
            ?assertEqual(ok, Result3)
    after 1000 ->
        error(timeout)
    end,
    
    %% Parent should still hold its lock
    ?assertEqual(true, local_lock:held()),
    ?assertEqual(ok, local_lock:release()).