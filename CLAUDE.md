# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FunnelKVS is a distributed key-value store implemented in Erlang/OTP using the Chord protocol for distributed hash table (DHT) functionality. The system provides fault-tolerant, scalable storage with consistent hashing for data distribution.

## Build & Development Commands

```bash
# Compile the project
make

# Run tests
make test

# Clean build artifacts
make clean

# Start a node
make run-node NODE_ID=1 PORT=8001

# Start the client tool
make client

# Run dialyzer for type checking
make dialyze

# Generate documentation
make docs

# Run all checks (compile, test, dialyze)
make check
```

## Architecture

### Core Components

- **Chord Module** (`src/chord.erl`): Implements the Chord DHT protocol including finger tables, successor/predecessor management, and ring stabilization
- **KVS Module** (`src/kvs.erl`): Key-value storage layer with replication and consistency management
- **Server Module** (`src/funnelkvs_server.erl`): Network server handling client connections and request routing
- **Client Module** (`src/funnelkvs_client.erl`): Client library and CLI tool for interacting with the cluster
- **Protocol Module** (`src/funnelkvs_protocol.erl`): Binary protocol encoder/decoder for client-server communication

### Key Design Principles

1. **No External Dependencies**: Use only Erlang/OTP standard library
2. **Consistent Hashing**: SHA-1 based hash ring for data distribution
3. **Replication**: Each key replicated to N successor nodes (typically N=3)
4. **Fault Tolerance**: Handle node failures through successor lists and periodic stabilization
5. **In-Memory Only**: No persistent storage, data lives only in memory

### Protocol Format

Binary protocol with request-response pattern:
- Request: `<<Type:8, KeyLen:32, Key:KeyLen/binary, ValueLen:32, Value:ValueLen/binary>>`
- Response: `<<Status:8, ValueLen:32, Value:ValueLen/binary>>`
- Operations: GET (0x01), PUT (0x02), DELETE (0x03)

## Testing Strategy

- Unit tests for each module in `test/*_tests.erl`
- Property-based tests using PropEr for protocol and hashing
- Integration tests simulating multi-node scenarios
- Common test suites for distributed system testing

## Directory Structure

```
.
├── src/                 # Source code
├── test/               # Test files
├── include/            # Header files (.hrl)
├── ebin/              # Compiled beam files
├── doc/               # Generated documentation
└── Makefile           # Build configuration
```

## Development Notes

- Use OTP behaviors (gen_server, gen_statem) for process management
- Implement supervisor trees for fault tolerance
- Use ETS tables for local key-value storage
- Maintain high test coverage for all modules
- Keep functions small and focused for readability
- Document complex algorithms, especially Chord operations