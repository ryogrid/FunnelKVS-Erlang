-module(single_lock_principle_tests).
-include_lib("eunit/include/eunit.hrl").

%% Test comprehensive Single Lock Principle adherence
comprehensive_single_lock_test() ->
    % Verify initial state
    ?assertEqual(false, local_lock:held()),
    
    % Test that we can acquire and release
    ?assertEqual(ok, local_lock:acquire()),
    ?assertEqual(true, local_lock:held()),
    
    % Test Single Lock Principle - cannot acquire when holding
    ?assertEqual({error, already_holding_lock}, local_lock:acquire()),
    ?assertEqual({error, already_holding_lock}, local_lock:acquire(named_lock)),
    
    % Still holding the original lock
    ?assertEqual(true, local_lock:held()),
    
    % Release and verify we can acquire again
    ?assertEqual(ok, local_lock:release()),
    ?assertEqual(false, local_lock:held()),
    ?assertEqual(ok, local_lock:acquire()),
    ?assertEqual(ok, local_lock:release()).

%% Test parallel workers with lock enforcement
parallel_workers_lock_test() ->
    Parent = self(),
    
    % Spawn multiple workers that try to acquire locks simultaneously
    Workers = [spawn(fun() ->
        Result = local_lock:acquire(worker_lock),
        Parent ! {worker_result, self(), Result},
        
        % Each worker should successfully acquire its own lock
        case Result of
            ok ->
                % Verify we hold the lock
                true = local_lock:held(),
                % Try to acquire another lock (should fail per Single Lock Principle)
                {error, already_holding_lock} = local_lock:acquire(another_lock),
                % Release
                ok = local_lock:release(worker_lock),
                false = local_lock:held();
            _ ->
                error
        end,
        
        Parent ! {worker_done, self()}
    end) || _ <- lists:seq(1, 3)],
    
    % Collect results - all workers should succeed since they're separate processes
    Results = [receive {worker_result, Pid, Result} -> {Pid, Result} end || Pid <- Workers],
    
    % Wait for all workers to finish
    [receive {worker_done, Pid} -> ok end || Pid <- Workers],
    
    % All workers should have successfully acquired their locks (different processes)
    lists:foreach(fun({_Pid, Result}) -> ?assertEqual(ok, Result) end, Results).

%% Test timeout behavior preserves Single Lock Principle
timeout_preserves_lock_principle_test() ->
    % Test that timeout operations don't interfere with lock principle
    Nodes = ['timeout_node@localhost'],
    
    % Acquire a lock before calling parallel_rpc
    ?assertEqual(ok, local_lock:acquire()),
    
    % Call parallel_rpc (should work in separate workers)
    {ok, Results} = parallel_rpc:execute_parallel_calls(
        Nodes, timer, sleep, [1], 
        [{rpc_timeout, 10}, {overall_timeout, 50}]
    ),
    
    % Verify our lock is still held (parallel_rpc doesn't affect main process)
    ?assertEqual(true, local_lock:held()),
    ?assertEqual(1, length(Results)),
    
    % Release our lock
    ?assertEqual(ok, local_lock:release()).