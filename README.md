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

### Implemented (Phase 3 - 100% Complete)
- ✅ **RPC framework** for multi-node communication
- ✅ **TCP-based RPC** with binary protocol handshake
- ✅ **Remote procedure calls**: find_successor, notify, transfer_keys, get_predecessor
- ✅ **Concurrent RPC connections** support
- ✅ **Multi-node test framework** with comprehensive test coverage
- ✅ **Asynchronous stabilization** preventing deadlocks
- ✅ **Two-node ring formation** with bidirectional links
- ✅ **Join protocol** with reciprocal notifications
- ✅ **Notify mechanism** for ring topology updates
- ✅ **Multi-node rings** (4+ nodes tested and working)
- ✅ **Key migration** with proper ownership transfer
- ✅ **Graceful departure** with key handoff
- ✅ **Multi-node routing** fixed - all operations work correctly
- ✅ **Key responsibility** properly determined by predecessor
- ✅ **Finger table updates** - automatically populated during stabilization
- ✅ **Failure detection** - automatic detection and ring repair
- ✅ **Successor list** - maintains backup successors for fault tolerance

### Planned (Phase 4)
- 📋 Successor-list replication (N=3)
- 📋 Replica synchronization
- 📋 Quorum-based reads/writes

### Planned (Phase 5-6)
- 📋 Conflict resolution (last-write-wins)
- 📋 Anti-entropy protocol
- 📋 OTP supervision trees
- 📋 Performance optimizations

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

### Multi-Node Ring Setup (Phase 3)

```erlang
% Start first node and create ring
{ok, Node1} = chord:start_node(1, 9001).
ok = chord:create_ring(Node1).

% Start second node and join the ring
{ok, Node2} = chord:start_node(2, 9002).
ok = chord:join_ring(Node2, "localhost", 9001).

% The two-node ring will automatically stabilize
% Both nodes will have bidirectional links after ~1-2 seconds

% Store and retrieve data
ok = chord:put(Node1, <<"key1">>, <<"value1">>).
{ok, <<"value1">>} = chord:get(Node2, <<"key1">>).
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
erl -pa ebin -noshell -s demo_phase3 run -s init stop
```

### Test Coverage
- **95+ unit tests** across all modules
- **Integration tests** for end-to-end workflows  
- **Protocol tests** for binary encoding/decoding
- **Chord tests** for DHT operations
- **RPC tests** for multi-node communication
- **Multi-node tests** for distributed scenarios
  - ✅ Two-node ring formation (passing)
  - ✅ Multi-node stabilization (4+ nodes, passing)
  - ✅ Key migration with ownership transfer (passing)
  - ⚠️ Graceful departure (implemented but routing issues)
  - 🚧 Failure detection (not implemented)

## Performance

Current single-node performance (Phase 1):
- **Throughput**: 4,500+ operations/second
- **Latency**: Sub-millisecond for local operations
- **Concurrent clients**: Successfully tested with 100+ concurrent connections

## Development Status

### Recent Improvements (Phase 3 Complete!)
- **Fixed**: Routing loops in multi-node rings (major breakthrough!)
- **Implemented**: Finger table population for O(log N) lookups
- **Implemented**: Failure detection with automatic ring repair
- **Added**: Successor list for fault tolerance
- **Achievement**: Phase 3 100% complete - all features working!

### Phase Completion
- ✅ **Phase 1**: Basic KVS with TCP server/client (100% complete)
- ✅ **Phase 2**: Chord DHT foundation (100% complete)
- ✅ **Phase 3**: Node join/leave protocols (100% complete)
- 📋 **Phase 4**: Replication & consistency (planned)
- 📋 **Phase 5**: Production features (planned)
- 📋 **Phase 6**: Client tools & documentation (planned)

### Roadmap

#### Phase 3 (Complete - 100%)
- [x] RPC framework for node communication
- [x] TCP-based RPC with handshake protocol
- [x] Remote procedure calls implementation
- [x] Multi-node test framework
- [x] Asynchronous stabilization (prevents deadlocks)
- [x] Two-node ring formation (fully working)
- [x] Join protocol with reciprocal notifications
- [x] Multi-node rings (4+ nodes tested and working)
- [x] Key migration with ownership transfer
- [x] Graceful node departure with key handoff
- [x] Fix routing issues in multi-node operations
- [x] Finger table population during stabilization
- [x] Failure detection and automatic ring repair
- [x] Successor list maintenance

#### Phase 4 (Next)
- [ ] Successor-list replication (N=3)
- [ ] Replica synchronization
- [ ] Quorum-based reads/writes

#### Phase 5
- [ ] OTP supervision tree
- [ ] Configuration management
- [ ] Monitoring and metrics
- [ ] Performance optimizations
- [ ] Conflict resolution (last-write-wins)
- [ ] Anti-entropy protocol

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
│   ├── chord_rpc.erl   # RPC framework for multi-node
│   ├── funnelkvs_*.erl # Server, client, protocol
├── test/               # Test files
│   ├── *_tests.erl    # Unit tests
│   ├── chord_rpc_tests.erl # RPC tests
│   └── chord_multinode_tests.erl # Multi-node tests
├── include/            # Header files
│   └── chord.hrl      # Chord data structures
├── demo*.erl          # Demo scripts for each phase
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

## Troubleshooting

### Common Issues

**Port Already in Use**
- Ensure no other nodes are running on the same port
- Tests use ports 9xxx to avoid conflicts with production ports

**Node Join Timeout**
- Wait 1-2 seconds after join for stabilization
- Check network connectivity between nodes
- Verify the bootstrap node is running and accessible

**Test Failures**
- Some multi-node tests are still in development
- Run individual test modules: `make test-module MODULE=chord_multinode_tests`
- Check PHASE3_STATUS.md for known issues

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

![Tests](https://img.shields.io/badge/tests-95%2B%20passing-brightgreen)
![Phase](https://img.shields.io/badge/phase-3%20(100%25)-brightgreen)
![Erlang](https://img.shields.io/badge/erlang-%E2%89%A524-red)
![License](https://img.shields.io/badge/license-MIT-blue)