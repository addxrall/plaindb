APP     = build/PlainDB.app
BIN     = $(APP)/Contents/MacOS/PlainDB
PQ      = /opt/homebrew/opt/libpq
SRC     = $(wildcard src/*.m)
HDR     = $(wildcard src/*.h)
RES     = $(wildcard Resources/*.lproj/* Resources/*.icns)
CFLAGS  = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -g -O1 -I$(PQ)/include
LDFLAGS = -framework Cocoa -framework QuartzCore -framework Security -L$(PQ)/lib -lpq

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
	clang $(CFLAGS) -Isrc tests/grid_test.m src/GridView.m src/JSONInspector.m src/SQLText.m src/UI.m src/DBConnection.m -framework Cocoa -o build/grid_test
	clang $(CFLAGS) -Isrc tests/json_test.m src/JSONInspector.m src/SQLText.m src/UI.m src/DBConnection.m -framework Cocoa -o build/json_test
	./build/pg_test
	./build/grid_test
	./build/json_test
	python3 -I tests/check_strings.py

# Scroll performance of the grid (opens a window for a few seconds; timings depend on the machine)
perf: tests/perf_grid.m $(SRC) $(HDR)
	mkdir -p build
	clang $(CFLAGS) -Isrc tests/perf_grid.m src/GridView.m src/JSONInspector.m src/SQLText.m src/UI.m src/DBConnection.m -framework Cocoa -framework QuartzCore -o build/perf_grid
	./build/perf_grid

clean:
	rm -rf build

.PHONY: run install test perf clean
