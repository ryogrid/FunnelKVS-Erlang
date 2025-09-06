# Design and Implementation Plan for FunnelKVS

## 1. System Architecture Overview

### 1.1 High-Level Design

FunnelKVS is a distributed key-value store built on the Chord protocol, providing a scalable, fault-tolerant storage system with no single point of failure. The system consists of multiple nodes forming a logical ring, where each node is responsible for a portion of the key space.

### 1.2 Core Components

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

### 1.3 Module Structure

- **chord**: Implements Chord protocol with consistent hashing
- **kvs_store**: Local key-value storage using ETS tables
- **kvs_replication**: Handles data replication across nodes
- **kvs_server**: TCP server for client connections
- **kvs_protocol**: Binary protocol encoder/decoder
- **kvs_client**: Client library and CLI tool
- **kvs_supervisor**: OTP supervisor tree
- **kvs_app**: OTP application module

## 2. Chord Protocol Implementation

### 2.1 Node Identification

- Each node has a unique ID generated using SHA-1 hash of IP:Port
- Key space: 160-bit (SHA-1 output)
- Node IDs and keys share the same identifier space

### 2.2 Finger Table Structure

```erlang
-record(finger_entry, {
    start :: integer(),      % Start of finger interval
    interval :: {integer(), integer()}, % [start, start + 2^(i-1))
    node :: node_info()      % Successor node for this interval
}).

-record(node_info, {
    id :: integer(),         % Node ID (SHA-1 hash)
    ip :: inet:ip_address(),
    port :: inet:port_number(),
    pid :: pid()            % Process ID for local nodes
}).
```

### 2.3 Core Operations

**Find Successor**: O(log N) lookup
```
find_successor(Key):
    if Key ∈ (node.id, successor.id]:
        return successor
    else:
        n' = closest_preceding_node(Key)
        return n'.find_successor(Key)
```

**Stabilization**: Periodic maintenance
```
stabilize():
    x = successor.predecessor
    if x ∈ (node.id, successor.id):
        successor = x
    successor.notify(node)

notify(n'):
    if predecessor is nil or n' ∈ (predecessor.id, node.id):
        predecessor = n'
```

**Fix Fingers**: Update finger table entries
```
fix_fingers():
    next = next + 1
    if next > m:
        next = 1
    finger[next].node = find_successor(finger[next].start)
```

### 2.4 Node Join/Leave

**Join Process**:
1. New node n joins via existing node n'
2. Initialize finger table using n'
3. Update fingers of existing nodes
4. Transfer keys from successor

**Leave Process**:
1. Transfer all keys to successor
2. Notify predecessor to update successor
3. Other nodes detect failure through periodic checks

## 3. Data Management

### 3.1 Consistent Hashing

- Key distribution using SHA-1: `hash(key) mod 2^160`
- Each node responsible for keys in range (predecessor.id, node.id]
- Load balancing through uniform hash distribution

### 3.2 Replication Strategy

- **Replication Factor**: N = 3 (configurable)
- **Successor-list replication**: Store copies on N successive nodes
- **Write strategy**: Write to primary and wait for W confirmations (W = 2)
- **Read strategy**: Read from R nodes and return most recent (R = 2)
- **Consistency**: W + R > N ensures read-your-write consistency

### 3.3 Fault Tolerance

- **Failure Detection**: Timeout-based with exponential backoff
- **Recovery**: Rebuild replicas from remaining copies
- **Successor Lists**: Maintain list of r successors for quick failover
- **Periodic Synchronization**: Anti-entropy using Merkle trees

## 4. Binary Protocol Specification

### 4.1 Message Format

```
Request:
┌──────────┬──────────┬──────────┬─────────┬──────────┬───────┐
│ Magic    │ Version  │ Op Code  │ Key Len │ Key      │Value* │
│ (2 bytes)│ (1 byte) │ (1 byte) │(4 bytes)│(variable)│       │
└──────────┴──────────┴──────────┴─────────┴──────────┴───────┘

*Value field (for PUT operations):
┌──────────┬───────────┐
│ Val Len  │ Value     │
│ (4 bytes)│ (variable)│
└──────────┴───────────┘

Response:
┌──────────┬──────────┬──────────┬──────────┬───────────┐
│ Magic    │ Version  │ Status   │ Val Len  │ Value     │
│ (2 bytes)│ (1 byte) │ (1 byte) │ (4 bytes)│ (variable)│
└──────────┴──────────┴──────────┴──────────┴───────────┘
```

### 4.2 Operation Codes

- `0x01`: GET - Retrieve value for key
- `0x02`: PUT - Store key-value pair
- `0x03`: DELETE - Remove key
- `0x04`: PING - Health check
- `0x05`: STATS - Get node statistics

### 4.3 Status Codes

- `0x00`: SUCCESS
- `0x01`: KEY_NOT_FOUND
- `0x02`: INVALID_REQUEST
- `0x03`: SERVER_ERROR
- `0x04`: TIMEOUT
- `0x05`: NODE_NOT_RESPONSIBLE

## 5. Implementation Plan

### Phase 1: Foundation (Week 1)
**Goal**: Basic infrastructure and single-node KVS

**Tasks**:
1. Project structure setup with GNU Make
2. Implement basic KVS store using ETS
3. Binary protocol encoder/decoder
4. Simple TCP server
5. Basic client library

**Deliverables**:
- Single-node KVS with GET/PUT/DELETE
- Unit tests for store and protocol
- Simple CLI client

**Testing**: Unit tests for all modules

### Phase 2: Chord Protocol Core (Week 2)
**Goal**: Implement Chord DHT basics

**Tasks**:
1. Node ID generation and ring structure
2. Finger table implementation
3. Find successor algorithm
4. Basic stabilization routine
5. Successor list maintenance

**Deliverables**:
- Working Chord ring with 2-3 nodes
- Key routing functionality
- Finger table visualization tool

**Testing**: 
- Unit tests for Chord operations
- Integration tests for ring formation

### Phase 3: Node Join/Leave (Week 3)
**Goal**: Dynamic ring membership

**Tasks**:
1. Node join protocol
2. Key transfer on join
3. Graceful node departure
4. Failure detection
5. Finger table fixing algorithm

**Deliverables**:
- Nodes can join/leave dynamically
- Automatic key redistribution
- Ring stabilization under churn

**Testing**:
- Node join/leave scenarios
- Concurrent join tests
- Failure recovery tests

### Phase 4: Replication & Consistency (Week 4)
**Goal**: Data replication and fault tolerance

**Tasks**:
1. Successor-list replication
2. Replica synchronization
3. Quorum-based reads/writes

**Deliverables**:
- N-way replication (N=3)
- Automatic replica repair
- Configurable consistency levels

**Testing**:
- Replication correctness
- Consistency under failures
- Partition tolerance tests

### Phase 5: Production Features (Week 5)
**Goal**: Production-ready features and advanced consistency

**Tasks**:
1. OTP supervision tree
2. Configuration management
3. Monitoring and statistics
4. Performance optimization
5. Load balancing improvements
6. Conflict resolution (last-write-wins)
7. Anti-entropy protocol

**Deliverables**:
- Fault-tolerant OTP application
- Node statistics and monitoring
- Performance benchmarks

**Testing**:
- System-level integration tests
- Performance benchmarks
- Stress testing

### Phase 6: Client & Tools (Week 6)
**Goal**: User-facing tools and documentation

**Tasks**:
1. Enhanced CLI client
2. Batch operations support
3. Admin tools (ring status, rebalancing)
4. Comprehensive documentation
5. Example applications

**Deliverables**:
- Feature-complete CLI
- Admin tools
- User documentation
- API documentation

**Testing**:
- End-to-end tests
- User acceptance tests

## 6. Testing Strategy

### 6.1 Unit Testing
- Test each module in isolation
- Property-based testing with PropEr for protocols
- Coverage target: >80%

### 6.2 Integration Testing
- Multi-node scenarios
- Network partition simulation
- Concurrent operation testing

### 6.3 System Testing
- Full cluster deployment
- Failure injection
- Performance benchmarking

### 6.4 Test Scenarios
1. **Basic Operations**: GET/PUT/DELETE correctness
2. **Consistency**: Read-after-write, eventual consistency
3. **Fault Tolerance**: Node failures, network partitions
4. **Performance**: Throughput, latency under load
5. **Scalability**: Adding/removing nodes under load

## 7. Performance Targets

- **Throughput**: 10,000+ ops/sec per node
- **Latency**: <10ms p99 for local operations
- **Scalability**: Linear scaling up to 100 nodes
- **Recovery**: <1 second detection, <10 seconds redistribution

## 8. Risk Mitigation

### Technical Risks
1. **Network Partitions**: Implement partition detection and resolution
2. **Hot Spots**: Virtual nodes for better load distribution
3. **Cascading Failures**: Circuit breakers and backpressure
4. **Data Loss**: Aggressive replication and checksums

### Implementation Risks
1. **Complexity**: Incremental development with continuous testing
2. **Debugging**: Comprehensive logging and tracing
3. **Performance**: Early benchmarking and profiling

## 9. Success Criteria

- All basic operations (GET/PUT/DELETE) work correctly
- System remains available under node failures (up to N-1)
- Consistent performance under normal load
- Clean, readable, and well-documented code
- Comprehensive test coverage
- No external dependencies