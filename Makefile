# FunnelKVS Makefile
# Distributed Key-Value Store using Chord Protocol

ERLC = erlc
ERL = erl
ERLC_FLAGS = -Wall +debug_info -I include -o ebin

# Source and test directories
SRC_DIR = src
TEST_DIR = test
EBIN_DIR = ebin
INCLUDE_DIR = include

# Find all source and test files
SOURCES = $(wildcard $(SRC_DIR)/*.erl)
TESTS = $(wildcard $(TEST_DIR)/*.erl)
BEAMS = $(patsubst $(SRC_DIR)/%.erl,$(EBIN_DIR)/%.beam,$(SOURCES))
TEST_BEAMS = $(patsubst $(TEST_DIR)/%.erl,$(EBIN_DIR)/%.beam,$(TESTS))

# Default target
all: compile

# Compile all source files
compile: $(EBIN_DIR) $(BEAMS)

# Compile tests
compile-tests: compile $(TEST_BEAMS)

# Pattern rule for compiling .erl to .beam
$(EBIN_DIR)/%.beam: $(SRC_DIR)/%.erl
	$(ERLC) $(ERLC_FLAGS) $<

$(EBIN_DIR)/%.beam: $(TEST_DIR)/%.erl
	$(ERLC) $(ERLC_FLAGS) $<

# Create ebin directory if it doesn't exist
$(EBIN_DIR):
	mkdir -p $(EBIN_DIR)

# Run tests
test: compile-tests
	@echo "Running tests..."
	@for test in $(patsubst $(TEST_DIR)/%.erl,%,$(TESTS)); do \
		echo "Testing $$test..."; \
		$(ERL) -noshell -pa $(EBIN_DIR) \
			-eval "case eunit:test($$test, [verbose]) of ok -> init:stop(0); _ -> init:stop(1) end" || exit 1; \
	done

# Run a single test module
test-module: compile-tests
	@echo "Running test module: $(MODULE)"
	@$(ERL) -noshell -pa $(EBIN_DIR) \
		-eval 'eunit:test($(MODULE), [verbose]), init:stop()'

# Start a node
run-node: compile
	@echo "Starting node with ID=$(NODE_ID) PORT=$(PORT)"
	@$(ERL) -pa $(EBIN_DIR) -name node$(NODE_ID)@127.0.0.1 \
		-eval 'application:start(funnelkvs)' \
		-funnelkvs port $(PORT)

# Start the client
client: compile
	@$(ERL) -pa $(EBIN_DIR) -noshell \
		-eval 'funnelkvs_client:start(), init:stop()'

# Interactive shell for development
shell: compile
	@$(ERL) -pa $(EBIN_DIR)

# Clean build artifacts
clean:
	rm -rf $(EBIN_DIR)/*.beam
	rm -rf erl_crash.dump
	rm -rf doc/*.html doc/*.css doc/*.png

# Generate documentation
docs:
	@echo "Generating documentation..."
	@$(ERL) -noshell -pa $(EBIN_DIR) \
		-eval 'edoc:application(funnelkvs, ".", []), init:stop()'

# Dialyzer for type checking
dialyze: compile
	@echo "Running dialyzer..."
	@dialyzer --build_plt --apps erts kernel stdlib
	@dialyzer $(EBIN_DIR)/*.beam

# Check everything (compile, test, dialyze)
check: compile test dialyze
	@echo "All checks passed!"

# Development helpers
watch:
	@echo "Watching for file changes..."
	@while true; do \
		inotifywait -q -e modify,create,delete -r $(SRC_DIR) $(TEST_DIR); \
		clear; \
		make test; \
	done

# Show help
help:
	@echo "FunnelKVS Makefile targets:"
	@echo "  make              - Compile the project"
	@echo "  make test         - Run all tests"
	@echo "  make test-module MODULE=<name> - Run specific test module"
	@echo "  make run-node NODE_ID=<id> PORT=<port> - Start a node"
	@echo "  make client       - Start the client tool"
	@echo "  make shell        - Start interactive Erlang shell"
	@echo "  make clean        - Remove build artifacts"
	@echo "  make docs         - Generate documentation"
	@echo "  make dialyze      - Run dialyzer type checker"
	@echo "  make check        - Run all checks"
	@echo "  make watch        - Auto-run tests on file changes"
	@echo "  make help         - Show this help"

.PHONY: all compile compile-tests test test-module run-node client shell clean docs dialyze check watch help