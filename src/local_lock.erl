%% @doc Very simple per-process single-lock guard.
%%      - Ensures a process never holds more than one lock-equivalent.
%%      - Non-blocking: acquire returns {error, already_holding_lock} if held.
%%      - No monitoring, no ordering, no distributed coordination.

-module(local_lock).
-export([
    acquire/0,
    acquire/1,
    release/0,
    release/1,
    held/0
]).

%% Acquire a single anonymous lock for current process.
acquire() ->
    case get('$local_lock_held') of
        undefined ->
            put('$local_lock_held', true),
            ok;
        true ->
            {error, already_holding_lock}
    end.

%% Acquire a named lock (name is for logging/diagnosis only).
acquire(_Name) ->
    acquire().

%% Release the held lock (anonymous).
release() ->
    case get('$local_lock_held') of
        true ->
            erase('$local_lock_held'),
            ok;
        _ ->
            {error, not_held}
    end.

%% Release the held lock (named).
release(_Name) ->
    release().

%% Check if current process holds the lock.
held() ->
    case get('$local_lock_held') of
        true -> true;
        _ -> false
    end.