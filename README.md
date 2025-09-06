# FunnelKVS-Erlang

A distributed key-value store implementation in Erlang/OTP using the Chord distributed hash table (DHT) protocol.

## Overview

FunnelKVS is a scalable, fault-tolerant distributed key-value storage system built entirely with Erlang/OTP standard library (no external dependencies). It implements the Chord protocol for distributed hash table functionality, providing efficient key lookup with O(log N) complexity in a network of N nodes.

## Features

### Implemented (Phase 1 & 2)
- ✅ **In-memory key-value storage** using ETS tables
- ✅ **Binary protocol** with magic bytes and versioning
- ✅ **TCP server** with concurrent client handling
- ✅ **Client library** with connection pooling
- ✅ **Command-line interface** with interactive shell
- ✅ **SHA-1 based consistent hashing** (160-bit identifier space)
- ✅ **Chord DHT foundation**:
  - Node ID generation
  - Finger table structure
  - Find successor algorithm
  - Stabilization routines
  - Single-node ring operations

### In Progress (Phase 3-6)
- 🚧 Multi-node RPC communication
- 🚧 Dynamic node join/leave
- 🚧 Key migration and rebalancing
- 🚧 Replication (N=3 successor list)
- 🚧 Fault tolerance and recovery
- 🚧 Anti-entropy with Merkle trees

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Client Layer                      │
│              (CLI Tool & Client Library)             │
└─────────────────────────────────────────────────────┘
                           │
                    Binary Protocol
                           │
┌─────────────────────────────────────────────────────┐
│                     Node Layer                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │
│  │   Node 1    │  │   Node 2    │  │   Node N    │ │
│  │  ┌───────┐  │  │  ┌───────┐  │  │  ┌───────┐  │ │
│  │  │ Chord │  │  │  │ Chord │  │  │  │ Chord │  │ │
│  │  │  DHT  │  │  │  │  DHT  │  │  │  │  DHT  │  │ │
│  │  └───────┘  │  │  └───────┘  │  │  └───────┘  │ │
│  │  ┌───────┐  │  │  ┌───────┐  │  │  ┌───────┐  │ │
│  │  │  KVS  │  │  │  │  KVS  │  │  │  │  KVS  │  │ │
│  │  │ Store │  │  │  │ Store │  │  │  │ Store │  │ │
│  │  └───────┘  │  │  └───────┘  │  │  └───────┘  │ │
│  └─────────────┘  └─────────────┘  └─────────────┘ │
└─────────────────────────────────────────────────────┘
```

## Installation

### Prerequisites
- Erlang/OTP 24 or later
- GNU Make

### Building from Source

```bash
# Clone the repository
git clone https://github.com/ryogrid/FunnelKVS-Erlang.git
cd FunnelKVS-Erlang

# Compile the project
make

# Run tests
make test

# Run all checks (compile, test, dialyze)
make check
```

## Usage

### Starting a Single Node

```bash
# Start a node on port 8001
make run-node NODE_ID=1 PORT=8001
```

### Using the CLI Client

```bash
# Start the interactive client
make client

# Or connect to a specific server
erl -pa ebin -noshell -eval 'funnelkvs_client:start()' -s init stop
```

### Client Commands

```
funnelkvs> put user:alice "Alice Smith"
OK
funnelkvs> get user:alice
Value: Alice Smith
funnelkvs> delete user:alice
OK
funnelkvs> ping
pong
funnelkvs> stats
keys: 0, size: 0
funnelkvs> help
Available commands:
  get <key>           - Retrieve value for key
  put <key> <value>   - Store key-value pair
  delete <key>        - Delete key
  ping                - Check server connection
  stats               - Display server statistics
  help                - Show this help message
  quit                - Exit the client
```

### Programmatic Usage (Erlang)

```erlang
% Start a server
{ok, ServerPid} = funnelkvs_server:start_link(8001).

% Connect a client
{ok, ClientPid} = funnelkvs_client:connect("localhost", 8001).

% Store data
ok = funnelkvs_client:put(ClientPid, <<"key">>, <<"value">>).

% Retrieve data
{ok, Value} = funnelkvs_client:get(ClientPid, <<"key">>).

% Delete data
ok = funnelkvs_client:delete(ClientPid, <<"key">>).

% Disconnect
funnelkvs_client:disconnect(ClientPid).
```

## Binary Protocol

FunnelKVS uses a custom binary protocol for client-server communication:

### Request Format
```
┌──────────┬──────────┬──────────┬─────────┬──────────┬───────┐
│ Magic    │ Version  │ Op Code  │ Key Len │ Key      │Value* │
│ (3 bytes)│ (1 byte) │ (1 byte) │(4 bytes)│(variable)│       │
└──────────┴──────────┴──────────┴─────────┴──────────┴───────┘
```

### Response Format
```
┌──────────┬──────────┬──────────┬──────────┬───────────┐
│ Magic    │ Version  │ Status   │ Val Len  │ Value     │
│ (3 bytes)│ (1 byte) │ (1 byte) │ (4 bytes)│ (variable)│
└──────────┴──────────┴──────────┴──────────┴───────────┘
```

### Operation Codes
- `0x01` - GET
- `0x02` - PUT
- `0x03` - DELETE
- `0x04` - PING
- `0x05` - STATS

## Testing

```bash
# Run all tests
make test

# Run specific test module
make test-module MODULE=kvs_store_tests

# Run integration tests
erl -pa ebin -noshell -eval 'eunit:test(integration_tests, [verbose])' -s init stop

# Run demos
erl -pa ebin -noshell -s demo run -s init stop
erl -pa ebin -noshell -s demo_phase2 run -s init stop
```

### Test Coverage
- **74+ unit tests** across all modules
- **Integration tests** for end-to-end workflows
- **Protocol tests** for binary encoding/decoding
- **Chord tests** for DHT operations

## Performance

Current single-node performance (Phase 1):
- **Throughput**: 4,500+ operations/second
- **Latency**: Sub-millisecond for local operations
- **Concurrent clients**: Successfully tested with 100+ concurrent connections

## Development Status

### Phase Completion
- ✅ **Phase 1**: Basic KVS with TCP server/client (100% complete)
- ✅ **Phase 2**: Chord DHT foundation (100% complete)
- 🚧 **Phase 3**: Node join/leave protocols (0% complete)
- 📋 **Phase 4**: Replication & consistency (planned)
- 📋 **Phase 5**: Production features (planned)
- 📋 **Phase 6**: Client tools & documentation (planned)

### Roadmap

#### Phase 3 (Current)
- [ ] RPC framework for node communication
- [ ] Node join protocol with key transfer
- [ ] Graceful node departure
- [ ] Failure detection

#### Phase 4
- [ ] Successor list replication (N=3)
- [ ] Quorum-based reads/writes
- [ ] Anti-entropy protocol
- [ ] Conflict resolution

#### Phase 5
- [ ] OTP supervision tree
- [ ] Configuration management
- [ ] Monitoring and metrics
- [ ] Performance optimizations

#### Phase 6
- [ ] Enhanced CLI tools
- [ ] Admin dashboard
- [ ] Comprehensive documentation
- [ ] Example applications

## Project Structure

```
.
├── src/                 # Source code
│   ├── kvs_store.erl   # Local KV storage
│   ├── chord.erl       # Chord DHT protocol
│   ├── funnelkvs_*.erl # Server, client, protocol
├── test/               # Test files
├── include/            # Header files
├── ebin/              # Compiled beam files
├── doc/               # Documentation
└── Makefile           # Build configuration
```

## Development

### Building

```bash
make                # Compile
make clean         # Clean build artifacts
make dialyze       # Run type checker
make docs          # Generate documentation
```

### Code Style
- Follow Erlang/OTP conventions
- Use descriptive function and variable names
- Keep functions small and focused
- Document complex algorithms

### Testing Approach
This project follows **Test-First Development (TDD)**:
1. Write tests that define expected behavior
2. Implement minimal code to pass tests
3. Refactor while keeping tests green
4. Maintain high test coverage

## Contributing

Contributions are welcome! Please follow these steps:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Write tests for your changes
4. Implement your changes
5. Ensure all tests pass (`make test`)
6. Commit your changes (`git commit -m 'Add amazing feature'`)
7. Push to the branch (`git push origin feature/amazing-feature`)
8. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Based on the [Chord protocol](https://pdos.csail.mit.edu/papers/chord:sigcomm01/chord_sigcomm.pdf) by Ion Stoica et al.
- Built with Erlang/OTP
- Developed using test-first methodology

## Contact

- GitHub: [@ryogrid](https://github.com/ryogrid)
- Repository: [FunnelKVS-Erlang](https://github.com/ryogrid/FunnelKVS-Erlang)

## Status

![Tests](https://img.shields.io/badge/tests-74%20passing-brightgreen)
![Phase](https://img.shields.io/badge/phase-2%20of%206-orange)
![Erlang](https://img.shields.io/badge/erlang-%E2%89%A524-red)
![License](https://img.shields.io/badge/license-MIT-blue)