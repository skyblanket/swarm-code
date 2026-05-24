# swarm-code — terminal coding agent built in sw on the swarmrt runtime

SWARMRT ?= /Users/sky/swarmrt
SWC     := $(SWARMRT)/bin/swc

SRC_DIR := src
BIN     := bin/swarm-code

# All .sw files — let make rebuild on any change. Easier than
# maintaining this list by hand every time we add a module.
SOURCES := $(wildcard $(SRC_DIR)/*.sw)

TESTBIN := bin/swarm-code-test

.PHONY: all clean run test smoke

all: $(BIN)

$(BIN): $(SOURCES)
	@mkdir -p bin
	$(SWC) build $(SRC_DIR)/main.sw -o $(BIN)
	@echo "swarm-code: built $(BIN)"

# Test suite — builds and runs bin/swarm-code-test. Exits non-zero
# if any check fails, so `make test` works in CI / pre-commit.
test: $(TESTBIN)
	@./$(TESTBIN)

$(TESTBIN): $(SOURCES)
	@mkdir -p bin
	@$(SWC) build $(SRC_DIR)/test_runner.sw -o $(TESTBIN)

clean:
	rm -rf bin

run: $(BIN)
	./$(BIN)

# Smoke test — boots the binary in headless mode, runs one bash tool call,
# verifies the response. Used by tests/smoke.sh.
smoke: $(BIN)
	@BIN=./$(BIN) ./tests/smoke.sh

# Run the auto-generated module tests (24 originally, 8 currently passing).
test-all:
	@./tests/run_all.sh

# Handy one-liner for ad hoc testing against a local endpoint.
run-local: $(BIN)
	SWARM_CODE_ENDPOINT=http://localhost:8000 ./$(BIN)
