# Architecture

## Stack

- Swift 6 (strict concurrency) and AppKit. The whole UI is built in code, no xibs or storyboards.
- `libpq` from Homebrew (`/opt/homebrew/opt/libpq`), linked dynamically and imported through the module map in `src/CLibPQ`; SQLite from the system (`import SQLite3`).
- `/usr/bin/ssh` for tunnels, Security.framework for the Keychain.
- Fonts: Geist and Geist Mono (SIL OFL) in `Resources/Fonts`, registered through `ATSApplicationFontsPath`.
- Build: a `Makefile` running `swiftc` and assembling the `.app` (with `Info.plist` and `Resources`) by hand. There is no Xcode project. The tests link against the app's code built once as a static library (`build/kit/libPlainDBKit.a`, `@testable import PlainDBKit`).

## Files

| File | Role |
|---|---|
| `src/main.swift` | `AppDelegate`, menu, opening windows and tabs, saving open tabs, quit prompt for unsaved changes |
| `src/DB.swift` | `DBValue` (text, NULL, and SQLite's integer / real / BLOB storage classes), `DBResult`, `DBError`, the `DBConnection` protocol, `changeStatements` (grid changes → SQL), `inlineParams` (preview), schema editing statements, `L()` / `LN()` for UI strings |
| `src/PGConnection.swift` | Postgres implementation on `libpq`; schema read from `pg_catalog` |
| `src/SQLiteConnection.swift` | SQLite implementation on the system SQLite, or on a server through `RemoteSQLite`; schema from `sqlite_master` and `PRAGMA` table-valued functions (one query for the whole database); `plaindb_like` for searching; PocketBase relations and file fields from `_collections` |
| `src/RemoteSQLite.swift` | runs the SQLite helper over `ssh` (`Process`): sends it on stdin, waits for its hello, JSON lines both ways, ssh's stderr for errors, restarts a helper that died |
| `Resources/sqlite_remote.py` | the helper itself (Python 3 stdlib): opens the file on the server, executes requests, tags value types, enforces read-only with `query_only` and an authorizer |
| `src/SSHTunnel.swift` | `ssh -N -L` via `Process`, waiting for the port, reconnecting |
| `src/Connector.swift` | `connect(_:password:)`: tunnel (if any) plus database connection in the background, used by the Connections window, the toolbar switcher and for files |
| `src/ConnectionStore.swift` | `Connection` (a saved connection, local database or file; `Codable`, compatible with the plists of earlier versions), the plist in `~/Library/Application Support/PlainDB/connections.plist`, the Keychain (service `PlainDB`), recent files, saved tabs; falls back to data saved under the old name `Tabula` |
| `src/UI.swift` | design tokens (`Theme`, light and dark, named after the design's CSS variables), Geist fonts, `Motion` (curves, spring, Reduce Motion), `copyLocally` (pasteboard for this Mac only, marked concealed), `WindowBackground`, `Panel`, `PillButton`, `ToolButton`, `SlidingSegments`, `Switcher`, `RowView`, `CellView` and small layout helpers |
| `src/GridView.swift` | grid for a `DBResult` (row numbers, numeric alignment, change colours, row entrance animations); collects unsaved changes in the Data tab. Cells draw themselves (see DECISIONS.md, "Grid cells draw themselves"), including the checkbox and the ↗ / 🖼 badge |
| `src/SQLCompletion.swift` | what the SQL editor offers at the cursor (pure; tables, aliases, columns, functions, keywords; UTF-16 offsets like `NSTextView`) |
| `src/SQLCompleter.swift` | the completion list under the cursor: the editor's delegate, keys, the list window |
| `src/SQLText.swift` | SQL text view: highlighting, line number gutter, copying for this Mac only |
| `src/ReferencePopover.swift` | foreign key preview and row picker, and `CardPopover`, the design's popover card |
| `src/DatePicker.swift` | `ValueKind` (bool, date, time, timestamp, timestamptz), Postgres date text ↔ `Date`, the date picker popover with its own month view |
| `src/ImageValue.swift` | image detection and decoding for cell values, and the preview popover (images; for files also PDFs through PDFKit and Save As…) |
| `src/FileRefs.swift` | files kept elsewhere: which values are file keys (also Postgres arrays and JSON lists), S3 locations, PocketBase file names, what bytes are, and downloading with the `aws` CLI |
| `src/SchemaGraph.swift` | the diagram's model and layout, without AppKit: tables, foreign key edges, `schemaLayout` (ranks by references, ordering by neighbours, saved positions, neighbours mode) |
| `src/SchemaSheets.swift` | "Add Column…" / "Add Foreign Key…" sheets: form, live SQL preview, database errors in place |
| `src/DiagramView.swift` | draws the diagram (boxes, lines, dot grid) and handles selection, dragging, panning, the box menu, zoom, the Reset Layout spring and export |
| `src/JSONInspector.swift` | JSON side panel: tree and text modes; order-keeping JSON parser, pretty-printer and minifier |
| `src/ConnectWindowController.swift` | start window: Local tab (grid of databases on the local server), Saved tab (list, form, frame colour) and Files tab (recent SQLite files); files dropped on it open |
| `src/MainWindowController.swift` | connection window: sidebar, top row (connection, tabs, production badge, light / dark), Data / Structure / SQL / Diagram, find row, pending changes bar, status bar, JSON inspector panel, the production confirmation and the toast |
| `src/SettingsWindowController.swift` | Settings: interface language |
| `Resources/{en,pl}.lproj` | Polish strings; English and Polish plural rules |
| `tests/pg_test.swift` | `PGConnection` and `changeStatements` against a real local Postgres |
| `tests/sqlite_test.swift` | `SQLiteConnection` on temporary files, all of it twice (local, and through the helper run by the local `python3`): schema, parameters, values, search, timeout, read-only, PocketBase; then the helper's own guards, restarts, banners and errors |
| `tests/store_test.swift` | frame colour rules, recent files, tabs, loading plists saved by earlier versions |
| `tests/tunnel_test.swift` | the tunnel's status reaches every window sharing it |
| `tests/schema_test.swift` | schema editing statements and the inlined preview |
| `tests/completion_test.swift` | SQL completion: contexts, aliases, statements, strings and comments, replace ranges |
| `tests/diagram_test.swift` | diagram layout: parents left, cycles, no overlaps, saved positions, neighbours, column cap |
| `tests/file_test.swift` | file keys in values, S3 locations, PocketBase names, data kinds, the aws download with a fake `aws` script |
| `tests/grid_test.swift` | `GridView`: swapping results, change model, ⌫, cell editing, JSON cells opening the inspector |
| `tests/date_test.swift` | type → kind mapping and date/time round trips, time zones, DST |
| `tests/image_test.swift` | image detection and decoding (bytea hex, base64, data URI) |
| `tests/json_test.swift` | JSON helpers, highlighting, the inspector end to end, the completer |
| `tests/sheets_test.swift` | schema sheets' SQL, foreign key preview and picker, diagram hit-testing and export |
| `tests/connect_test.swift` | what the connection form saves, validation, frame colours, Settings' language and restart |
| `tests/check_strings.py` | every `L()`/`LN()` key is translated, with matching format specifiers |
| `tests/perf_grid.swift` | `make perf`: scroll timing, CPU and memory of the grid on a big page; fails above the 120 Hz frame budget |

## UI structure

The connection window is a full-size-content window with a transparent title bar. Its content view (`WindowBackground`) draws the window background, and on it float three rounded panels: the sidebar, the content and the JSON inspector, whose wrapper animates its width. An empty unified toolbar makes the title bar as tall as the design's top row, so the traffic lights sit in the sidebar's first row; the top row (connection pill, tabs, production badge) is part of the content. With a native tab bar showing, the content starts below it. Each tab, and each state within a tab (grid / loading / error, SQL idle / running / done / error / result), is a page of a `Switcher`: all pages pinned to its edges, only the selected one visible. Vertical stacks (`column`) pin every view's leading and trailing edges explicitly, because `.width` alignment leaves views with an intrinsic width narrow. Colours come from `Theme`, which resolves light and dark variants dynamically; layer colours are set in `updateLayer` with the view's appearance current. The light / dark button sets `NSApp.appearance` and remembers it.

## Flows

**Connecting.** `ConnectWindowController` calls `connect(_:password:)`, which on a background queue:
1. Optionally runs `SSHTunnel.start()`, which waits until `127.0.0.1:<free port>` accepts connections.
2. Opens a `PGConnection` (a `SQLiteConnection` for a file, without a tunnel).
3. Returns to the main actor, and `AppDelegate` creates a `MainWindowController`.

**Queries.** Each connection has its own serial queue (`queue`), because `libpq` doesn't support concurrent calls on one connection. `MainWindowController.run(_:done:failed:)` dispatches work to that queue and delivers the result and its duration on the main thread. Order is preserved, so when clicking through tables quickly the last click wins. The window writes no engine-specific SQL: time limits (`execute(_:_:timeout:)`), write transactions on a read-only session (`inWriteTransaction`), emptying a table and boolean literals come from the connection. Connection classes are `@unchecked Sendable`: their state is only touched on their queue.

**Tabs.** Every tab is a `MainWindowController`, made by the `AppDelegate` for the same `DBConnection` and `SSHTunnel` and added with `addTabbedWindow(_:ordered:)`; the window's `tabbingIdentifier` is the connection's `identity`, so other connections never join the group. Windows don't close their connection: the `AppDelegate` does, when the last window using it closes. The shared tunnel posts `SSHTunnel.statusNotification`, which every tab observes, and new tabs read its `connected` state. Opening a connection that already has windows opens a plain window without restoring tabs again. The open tabs (`openTable` of each, in tab order) are saved per identity in user defaults (`openTabs`) when a table or tab changes, a tab closes and the app quits; opening that connection again restores them, skipping tables that no longer exist.

**Files.** An SQLite file is a `Connection` like any other (`kind = sqlite`, `path`, `name`, `production` = read-only, `frame`); `connect` opens a `SQLiteConnection` for it. ⌘O, Finder's "Open With", the Files tab and dropped files all go through `AppDelegate.openFile(atPath:)`, and opening a window remembers the file in the recent list.

**SQLite on a server.** A saved connection with `kind = sqlite-ssh` (`sshHost`, `path`, `database` = the path). `connect` creates `SQLiteConnection(sshHost:path:readOnly:)`, whose `RemoteSQLite` launches `/usr/bin/ssh … -- <host> python3 -I -u -c '<bootstrap>'`; the bootstrap reads the helper (base64) from the first line of stdin and runs it, the second line is `{"path", "readonly"}`. The helper opens the file (`mode=rw`, never creating it), prints a hello, then answers `execute`, `writable` and `file` requests, one JSON line each, values tagged (`{"i"}`, `{"r"}`, `{"b"}`, text, null) so storage classes survive. Lines before the hello (a shell banner) are skipped; after it, an answer without the request's id closes the session. If the helper dies, the request in flight fails and the next one starts a new session. See DECISIONS.md for the safety rules.

**Files in S3 or PocketBase storage.** `GridView` shows 🖼 on `fileColumns` (PocketBase file fields, from `pocketBaseFiles(table:)`) and, with `detectsFileKeys` (the connection has `s3Bucket`), on values `fileKeys(in:)` accepts. A click goes to `MainWindowController`, which offers a menu when a value holds several files and builds an `ImagePreview` with a loader: `fetchS3File` (the connection's bucket, region and `awsProfile`, or PocketBase's S3 settings read from `_params` without its keys, object key `<collection>/<record>/<name>`), or `pocketBaseFile(collection:record:name:maxBytes:)` on the connection's queue (a local read, or the helper's `file` request over SSH; names checked, path kept inside `storage`).

**Values.** A value is `DBValue`: text or NULL, plus SQLite's integer, real and BLOB storage classes. Postgres params go through `PQexecParams` as untyped text, and Postgres infers the type from the column. SQLite has no such inference for columns without a declared type, so its values keep their storage class and are bound back with it; an edited cell takes the class of the value it replaces (`value(forText:replacing:)`). Several statements in one SQLite `execute` run inside a savepoint, all or nothing like one `PQexec`, unless the script manages transactions itself.

**Dropped connection.** If `ssh` dies after the tunnel was established, `SSHTunnel` restarts it on the same port every 2 s and reports the state to the status bar. A query sent during the outage fails. On the next `execute`, `PGConnection` sees `CONNECTION_BAD` and runs `PQreset`. The failed query is not retried, because it may already have written something.

**Editing.** `GridView` keeps changes locally, in three structures:
- `edits`: row → column → new value;
- `deletedRows`;
- `insertedRows`.

Then:
1. `MainWindowController` only allows editing tables with a primary key, which it reads from the structure query.
2. ⌘S turns the changes into SQL with `changeStatements`: DELETE first, then UPDATE, then INSERT, with values as params.
3. On production the SQL is shown in the confirmation over the window first.
4. Everything runs in one write transaction. Each UPDATE and DELETE must affect exactly 1 row, otherwise everything is rolled back. After an error the changes stay in the grid; after success a toast says how many rows were saved.

Switching table, page or sort order, closing the window or quitting with unsaved changes asks whether to discard them.

**Production.** A connection marked as production opens with `default_transaction_read_only=on` (Postgres) or `PRAGMA query_only` (SQLite; on a server the helper also refuses pragma writes and `ATTACH`). See DECISIONS.md.

**Language.** Settings stores the choice in the app's `AppleLanguages` default; AppKit picks the matching `.lproj` at launch, so the change applies after a restart, which Settings offers.
