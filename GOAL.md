# Goal
- Distributed Key-Value Store with distributed hash table technique

# Implementation Details
- Use Chord protocol for distributed hash table
- Multi-threaded architecture for handling concurrent requests
- Consistent hashing for data distribution across nodes
- Replication and fault tolerance mechanisms
- Simple server for nodes and client tool
- On-memory data storage only and no persistent storage

# Convention on Implementation
- Comprehensive unit testing and documentation
- No third-party dependencies
- Simple and compact codebase
- High readability

# Interface
- Simple key-value store API
- Support for basic operations: GET, PUT, DELETE
- Original binary protocol for communication
- Key and Value are both byte arrays
- Client and Server communicate using a request-response pattern
- Client tool can UTF-8 encode/decode keys and values

# Technical Stack
- Language: Earlang/OTP
- Only GNU Make. No Autotools or CMake