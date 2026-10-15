APP     = build/Tabula.app
BIN     = $(APP)/Contents/MacOS/Tabula
PQ      = /opt/homebrew/opt/libpq
SRC     = $(wildcard src/*.m)
HDR     = $(wildcard src/*.h)
CFLAGS  = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -g -O1 -I$(PQ)/include
LDFLAGS = -framework Cocoa -framework Security -L$(PQ)/lib -lpq

$(BIN): $(SRC) $(HDR) Info.plist
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/Info.plist
	clang $(CFLAGS) $(SRC) $(LDFLAGS) -o $@

run: $(BIN)
	open $(APP)

# Wymaga lokalnego Postgresa; baza z TABULA_TEST_DB (domyślnie postgres)
test: tests/pg_test.m src/PGConnection.m src/DBConnection.m $(HDR)
	mkdir -p build
	clang $(CFLAGS) -Isrc tests/pg_test.m src/PGConnection.m src/DBConnection.m -framework Foundation -L$(PQ)/lib -lpq -o build/pg_test
	./build/pg_test

clean:
	rm -rf build

.PHONY: run test clean
