# swarm-code — terminal coding agent built in sw on the swarmrt runtime

SWARMRT ?= /Users/sky/swarmrt
SWC     := $(SWARMRT)/bin/swc

SRC_DIR := src
BIN     := bin/swarm-code

SOURCES := $(SRC_DIR)/main.sw \
           $(SRC_DIR)/agent.sw \
           $(SRC_DIR)/llm.sw \
           $(SRC_DIR)/tools.sw \
           $(SRC_DIR)/prompts.sw

.PHONY: all clean run

all: $(BIN)

$(BIN): $(SOURCES)
	@mkdir -p bin
	$(SWC) build $(SRC_DIR)/main.sw -o $(BIN)
	@echo "swarm-code: built $(BIN)"

clean:
	rm -rf bin

run: $(BIN)
	./$(BIN)

# Handy one-liner for ad hoc testing against a local endpoint.
run-local: $(BIN)
	SWARM_CODE_ENDPOINT=http://localhost:8000 ./$(BIN)
