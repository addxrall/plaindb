APP     = build/PlainDB.app
BIN     = $(APP)/Contents/MacOS/PlainDB
PQ      = /opt/homebrew/opt/libpq
SRC     = $(wildcard src/*.swift)
LIB_SRC = $(filter-out src/main.swift,$(SRC)) # everything but the app's entry point, for the tests
RES     = $(wildcard Resources/*.lproj/* Resources/*.icns Resources/*.py Resources/Fonts/*)
SWIFTC  = swiftc -swift-version 6 -parse-as-library -I src/CLibPQ -Xcc -I$(PQ)/include
LDFLAGS = -L$(PQ)/lib -lpq
TESTS   = schema store tunnel completion diagram file sqlite pg grid date image json sheets connect

$(BIN): $(SRC) src/CLibPQ/* $(RES) Info.plist
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Info.plist $(APP)/Contents/Info.plist
	cp -R Resources/ $(APP)/Contents/Resources/
	$(SWIFTC) -module-name PlainDB -O -g $(SRC) $(LDFLAGS) -o $@

run: $(BIN)
	open $(APP)

LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

install: $(BIN)
	ditto $(APP) /Applications/PlainDB.app
	# macOS caches app icons: a new bundle date and registration make Finder and Launchpad reread it
	touch /Applications/PlainDB.app
	$(LSREGISTER) -f /Applications/PlainDB.app
	@echo "Installed /Applications/PlainDB.app (if the Dock still shows the old icon: killall Dock)"

# The app's code once, as a module the tests import with @testable.
build/kit/libPlainDBKit.a: $(LIB_SRC) src/CLibPQ/*
	mkdir -p build/kit
	$(SWIFTC) -module-name PlainDBKit -Onone -g -enable-testing -emit-library -static -emit-module \
		-emit-module-path build/kit/PlainDBKit.swiftmodule $(LIB_SRC) -o $@

build/%_test: tests/%_test.swift tests/Check.swift build/kit/libPlainDBKit.a
	$(SWIFTC) -Onone -g -I build/kit -L build/kit -lPlainDBKit $(LDFLAGS) tests/Check.swift $< -o $@

# pg_test needs a local Postgres; database from PLAINDB_TEST_DB (default: postgres). Tests with windows need a login session.
test: $(TESTS:%=build/%_test)
	for t in $(TESTS); do ./build/$${t}_test || exit 1; done
	python3 -I tests/check_strings.py

# Scroll performance of the grid (opens a window for a few seconds; timings depend on the machine)
perf: tests/perf_grid.swift tests/Check.swift $(LIB_SRC) src/CLibPQ/*
	mkdir -p build/kit-O
	$(SWIFTC) -module-name PlainDBKit -O -enable-testing -emit-library -static -emit-module \
		-emit-module-path build/kit-O/PlainDBKit.swiftmodule $(LIB_SRC) -o build/kit-O/libPlainDBKit.a
	$(SWIFTC) -O -I build/kit-O -L build/kit-O -lPlainDBKit $(LDFLAGS) tests/Check.swift tests/perf_grid.swift -o build/perf_grid
	./build/perf_grid

clean:
	rm -rf build

.PHONY: run install test perf clean
