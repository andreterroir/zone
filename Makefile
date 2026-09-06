BINARY      := agent
INSTALL_DIR := $(HOME)/bin
INSTALL_BIN := zone

.PHONY: all build install uninstall clean

all: build

build: $(BINARY)

$(BINARY): $(wildcard *.go) go.mod
	go build -o $(BINARY)

install: build
	install -d $(INSTALL_DIR)
	install -m 0755 $(BINARY) $(INSTALL_DIR)/$(INSTALL_BIN)

uninstall:
	rm -f $(INSTALL_DIR)/$(INSTALL_BIN)

clean:
	rm -f $(BINARY)
