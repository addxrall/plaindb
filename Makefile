APP     = build/PlainDB.app
BIN     = $(APP)/Contents/MacOS/PlainDB
PQ      = /opt/homebrew/opt/libpq
SRC     = $(wildcard src/*.m)
HDR     = $(wildcard src/*.h)
RES     = $(wildcard Resources/*.lproj/* Resources/*.icns)
GRID_SRC = src/GridView.m src/DatePicker.m src/ImageValue.m src/JSONInspector.m src/SQLText.m src/UI.m src/DBConnection.m # what GridView needs
CFLAGS  = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -g -O1 -I$(PQ)/include
LDFLAGS = -framework Cocoa -framework QuartzCore -framework Security -framework UniformTypeIdentifiers -L$(PQ)/lib -lpq -lsqlite3

$(BIN): $(SRC) $(HDR) $(RES) Info.plist
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Info.plist $(APP)/Contents/Info.plist
	cp -R Resources/ $(APP)/Contents/Resources/
	clang $(CFLAGS) $(SRC) $(LDFLAGS) -o $@

run: $(BIN)
	open $(APP)

LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

install: $(BIN)
	ditto $(APP) /Applications/PlainDB.app
	# macOS caches app icons: a new bundle date and registration make Finder and Launchpad reread it
	touch /Applications/PlainDB.app
	$(LSREGISTER) -f /Applications/PlainDB.app
	@echo "Installed /Applications/PlainDB.app (if the Dock still shows the old icon: killall Dock)"

# pg_test needs a local Postgres; database from PLAINDB_TEST_DB (default: postgres)
test: tests/*.m tests/*.py $(SRC) $(HDR) $(RES)
	mkdir -p build
	clang $(CFLAGS) -Isrc tests/pg_test.m src/PGConnection.m src/DBConnection.m -framework Foundation -L$(PQ)/lib -lpq -o build/pg_test
	clang $(CFLAGS) -Isrc tests/sqlite_test.m src/SQLiteConnection.m src/DBConnection.m -framework Foundation -lsqlite3 -o build/sqlite_test
	clang $(CFLAGS) -Isrc tests/grid_test.m $(GRID_SRC) -framework Cocoa -o build/grid_test
	clang $(CFLAGS) -Isrc tests/json_test.m src/JSONInspector.m src/SQLText.m src/UI.m src/DBConnection.m -framework Cocoa -o build/json_test
	clang $(CFLAGS) -Isrc tests/store_test.m src/ConnectionStore.m -framework Foundation -framework Security -o build/store_test
	clang $(CFLAGS) -Isrc tests/image_test.m src/ImageValue.m src/UI.m src/DBConnection.m -framework Cocoa -o build/image_test
	clang $(CFLAGS) -Isrc tests/date_test.m src/DatePicker.m src/UI.m src/DBConnection.m -framework Cocoa -o build/date_test
	clang $(CFLAGS) -Isrc tests/diagram_test.m src/SchemaGraph.m src/DBConnection.m -framework Foundation -o build/diagram_test
	clang $(CFLAGS) -Isrc tests/tunnel_test.m src/SSHTunnel.m -framework Foundation -o build/tunnel_test
	clang $(CFLAGS) -Isrc tests/schema_test.m src/DBConnection.m -framework Foundation -o build/schema_test
	clang $(CFLAGS) -Isrc tests/completion_test.m src/SQLCompletion.m src/SchemaGraph.m src/DBConnection.m -framework Foundation -o build/completion_test
	./build/pg_test
	./build/sqlite_test
	./build/grid_test
	./build/store_test
	./build/image_test
	./build/date_test
	./build/diagram_test
	./build/tunnel_test
	./build/schema_test
	./build/completion_test
	./build/json_test
	python3 -I tests/check_strings.py

# Scroll performance of the grid (opens a window for a few seconds; timings depend on the machine)
perf: tests/perf_grid.m $(SRC) $(HDR)
	mkdir -p build
	clang $(CFLAGS) -Isrc tests/perf_grid.m $(GRID_SRC) -framework Cocoa -framework QuartzCore -o build/perf_grid
	./build/perf_grid

clean:
	rm -rf build

.PHONY: run install test perf clean
