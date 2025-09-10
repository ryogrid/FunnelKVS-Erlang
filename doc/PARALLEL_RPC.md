# Parallel RPC (spawn-based, Single Lock Principle)

This module provides parallel RPC execution across nodes using `spawn/3`. It adheres strictly to the Single Lock Principle:
- Each worker holds at most one "lock-equivalent" at any time.
- No lock ordering and no process monitoring are used.
- The "lock-equivalent" is a local, per-process guard covering only the `rpc:call/5` critical section.

## Rationale

- Deadlocks require cycles in the wait-for graph. By construction, each worker holds at most one lock-equivalent and never attempts to acquire another, so cycles cannot form.
- The lock is local (per-process), non-blocking, and not distributed; it merely enforces the "at most one" property to maintain the invariant with minimal complexity.

## Public API

```erlang
parallel_rpc:execute_parallel_calls(Nodes, Module, Function, Args) ->
    {ok, Results} | {timeout, PartialResults}.

parallel_rpc:execute_parallel_calls(Nodes, Module, Function, Args, Opts) ->
    {ok, Results} | {timeout, PartialResults}.
%% Opts:
%%   - {rpc_timeout, Millis}        %% per-node rpc:call/5 timeout (default 5000)
%%   - {overall_timeout, Millis}    %% overall aggregate timeout (default 5000)
```

### Result shape

`Results` and `PartialResults` are lists of `{Node(), {ok, Term()} | {error, Term()}}`.

## Example

```erlang
Nodes = [ 'node1@host', 'node2@host', 'node3@host' ],
{ok, Results} =
    parallel_rpc:execute_parallel_calls(Nodes, my_mod, do_work, [Arg1, Arg2], [
        {rpc_timeout, 3000},
        {overall_timeout, 4000}
    ]).
```

## Design Notes

- Single Lock Principle is enforced by `local_lock`:
  - `acquire/1` returns `ok` if no lock is held in the current process, otherwise `{error, already_holding_lock}`.
  - The worker lifecycle guarantees it never attempts a second acquire.
- No lock ordering is required because each worker holds at most one lock.
- No process monitoring is used; on overall timeout, workers are canceled with `exit(Pid, kill)` best-effort.
- If your higher-level operation requires multi-node coordination, split it into phases so each phase holds at most one lock-equivalent. Avoid nested or chained acquisitions inside a single worker.