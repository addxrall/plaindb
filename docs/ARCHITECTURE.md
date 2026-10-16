# Architecture

## Stack

- Objective-C with ARC and AppKit. The whole UI is built in code, no xibs or storyboards.
- `libpq` from Homebrew (`/opt/homebrew/opt/libpq`), linked dynamically.
- `/usr/bin/ssh` for tunnels, Security.framework for the Keychain.
- Build: a `Makefile` running `clang` and assembling the `.app` (with `Info.plist` and `Resources/*.lproj`) by hand. There is no Xcode project.

## Files

| File | Role |
|---|---|
| `src/main.m` | `AppDelegate`, menu, opening windows, quit prompt for unsaved changes |
| `src/DBConnection.h/.m` | `DBConnection` protocol, `DBResult`, `DBQuoteIdent`, `DBError`, `DBChangeStatements` (grid changes → SQL), `DBInlineParams` (preview), `L()` / `LN()` for UI strings |
| `src/PGConnection.m` | Postgres implementation on `libpq`; schema read from `pg_catalog` |
| `src/SQLiteConnection.m` | SQLite implementation on the system `libsqlite3`, or on a server through `RemoteSQLite`; schema from `sqlite_master` and `PRAGMA` table-valued functions (one query for the whole database); `plaindb_like` for searching; PocketBase relations from `_collections` as foreign keys |
| `src/RemoteSQLite.m` | runs the SQLite helper over `ssh` (`NSTask`): sends it on stdin, waits for its hello, JSON lines both ways, ssh's stderr for errors, restarts a helper that died |
| `Resources/sqlite_remote.py` | the helper itself (Python 3 stdlib): opens the file on the server, executes requests, tags value types, enforces read-only with `query_only` and an authorizer |
| `src/SSHTunnel.m` | `ssh -N -L` via `NSTask`, waiting for the port, reconnecting |
| `src/Connector.m` | `TBConnect`: tunnel (if any) plus database connection in the background, used by the Connections window, the toolbar switcher and for files |
| `src/ConnectionStore.m` | plist in `~/Library/Application Support/PlainDB/connections.plist` and the Keychain (service `PlainDB`); falls back to data saved under the old name `Tabula`; recent SQLite files in user defaults |
| `src/UI.h/.m` | design tokens (`Theme`, light and dark), `TBCopyLocally` (pasteboard for this Mac only, marked concealed), small view helpers, `TBRowView`, `TBCellView`, `TBToolButton` (the design's 26 × 22 pt icon button), `TBFlippedView` |
| `src/GridView.m` | grid for a `DBResult` (row numbers, numeric alignment, change colours); collects unsaved changes in the Data tab. Cells are `GridCellView`s that draw themselves (see DECISIONS.md, "Grid cells draw themselves"), including the boolean checkbox and the ↗ / 🖼 badge; a click is matched against where the cell last drew its badge |
| `src/SQLCompletion.m` | what the SQL editor offers at the cursor (pure; tables, aliases, columns, functions, keywords) |
| `src/SQLCompleter.m` | the completion list under the cursor: the editor's delegate, keys, the list window |
| `src/SQLText.m` | SQL text view: highlighting, line number ruler |
| `src/ReferencePopover.m` | foreign key popovers: referenced row preview and the row picker |
| `src/DatePicker.m` | column kinds (bool, date, time, timestamp, timestamptz), Postgres date text ↔ `NSDate`, the date picker popover with its own month view (`CalendarView`) |
| `src/ImageValue.m` | image detection and decoding for cell values, and the preview popover (images; for files also PDFs through PDFKit and Save As…) |
| `src/FileRefs.m` | files kept elsewhere: which values are file keys (also Postgres arrays and JSON lists), S3 locations, PocketBase file names, what bytes are, and downloading with the `aws` CLI |
| `src/SchemaGraph.m` | the diagram's model and layout, without AppKit: tables, foreign key edges, `SchemaLayout` (ranks by references, ordering by neighbours, saved positions, neighbours mode) |
| `src/SchemaSheets.m` | "Add Column…" / "Add Foreign Key…" sheets: form, live SQL preview, database errors in place |
| `src/DiagramView.m` | draws the diagram (boxes, arrows) and handles selection, dragging, panning (background or middle button), the box menu, zoom keys and ⌘-wheel zoom |
| `src/JSONInspector.m` | JSON side panel (an `NSSplitViewController` inspector item): tree and text modes; order-keeping JSON parser, pretty-printer and minifier |
| `src/ConnectWindowController.m` | start window: Local tab (grid of databases on the local server), Saved tab (list, form, production frame colour) and Files tab (recent SQLite files); files dropped on it open |
| `src/MainWindowController.m` | connection window: sidebar, toolbar tabs Data / Structure / SQL, pending changes bar, status bar |
| `src/SettingsWindowController.m` | Settings: interface language |
| `Resources/{en,pl}.lproj` | Polish strings; English and Polish plural rules |
| `tests/pg_test.m` | `PGConnection` and `DBChangeStatements` against a real local Postgres |
| `tests/completion_test.m` | SQL completion: contexts, aliases, statements, strings and comments |
| `tests/schema_test.m` | schema editing statements (ADD COLUMN, ADD CONSTRAINT … FOREIGN KEY) |
| `tests/diagram_test.m` | diagram layout: parents left, cycles, no overlaps, saved positions, neighbours, column cap |
| `tests/tunnel_test.m` | the tunnel's status reaches every window sharing it |
| `tests/sqlite_test.m` | `SQLiteConnection` on temporary files, all of it twice (local, and through the helper run by the local `python3`): schema, parameters, values, search, timeout, read-only; then the helper's own guards, restarts, banners and errors |
| `tests/grid_test.m` | `GridView`: swapping results, change model, ⌫, cell editing, JSON cells opening the inspector |
| `tests/json_test.m` | JSON helpers: formatting keeps key order and string contents, parse tree |
| `tests/store_test.m` | window frame colour rules, including older saved connections |
| `tests/image_test.m` | image detection and decoding (bytea hex, base64, data URI) |
| `tests/file_test.m` | file keys in values, S3 locations, PocketBase names, data kinds, the aws download with a fake `aws` script |
| `tests/date_test.m` | type → kind mapping and date/time round trips, time zones, DST |
| `tests/check_strings.py` | every `L()`/`LN()` key is translated, with matching format specifiers |
| `tests/perf_grid.m` | `make perf`: scroll timing, CPU and memory of the grid on a big page; fails above the 120 Hz frame budget |

## UI structure

The connection window is an `NSSplitViewController` (sidebar + content) in a full-size-content window with a unified toolbar. The window shows the connection name and target as title and subtitle; the centered toolbar item is the Data / Structure / SQL segmented control. Each tab, and each state within a tab (grid / loading / error, SQL idle / running / done / error / result), is a page of a `TBSwitcher`: all pages pinned to its edges with constraints, only the selected one visible. Vertical stacks (`TBColumn`) pin every view's leading and trailing edges explicitly, because `NSLayoutAttributeWidth` alignment leaves views with an intrinsic width narrow and off to one side. Colours come from `Theme`, which resolves light and dark variants dynamically, so a switch of the system appearance needs no reload.

## Flows

**Connecting.** `ConnectWindowController`, on a background thread:
1. Optionally runs `SSHTunnel start`, which waits until `127.0.0.1:<free port>` accepts connections.
2. Calls `PGConnection open` (`SQLiteConnection open` for a file, without a tunnel).
3. Calls `onConnected` on the main thread, and `AppDelegate` creates a `MainWindowController`.

**Queries.** Each connection has its own serial queue (`queue`), because `libpq` doesn't support concurrent calls on one connection. `MainWindowController run:done:failed:` dispatches work to that queue and delivers the result and its duration on the main thread. Order is preserved, so when clicking through tables quickly the last click wins. The window writes no engine-specific SQL: time limits (`execute:params:timeout:error:`), write transactions on a read-only session (`inWriteTransaction:error:`), emptying a table and boolean literals come from the connection.

**Tabs.** Every tab is a `MainWindowController`, made by the `AppDelegate` for the same `id<DBConnection>` and `SSHTunnel` and added with `addTabbedWindow:ordered:`; the window's `tabbingIdentifier` is the connection's identity (`TBConnectionIdentity`), so other connections never join the group. Windows don't close their connection: the `AppDelegate` does, when the last window using it closes (`TBConnectionStillUsed`). The shared tunnel posts `SSHTunnelStatusNotification`, which every tab observes, and new tabs read its `connected` state. Opening a connection that already has windows opens a plain window without restoring tabs again. The open tabs (`openTable` of each, in tab order) are saved per identity in user defaults (`openTabs`) when a table or tab changes, a tab closes and the app quits; opening that connection again restores them, skipping tables that no longer exist.

**Files.** An SQLite file is a connection dictionary like any other (`kind = sqlite`, `path`, `name`, `production` = read-only, `frame`); `TBConnect` opens a `SQLiteConnection` for it. ⌘O, Finder's "Open With", the Files tab and dropped files all go through `AppDelegate openFileAtPath:`, and opening a window remembers the file in the recent list.

**SQLite on a server.** A saved connection with `kind = sqlite-ssh` (`sshHost`, `path`, `database` = the path). `TBConnect` creates `SQLiteConnection initWithSSHHost:path:readOnly:`, whose `RemoteSQLite` launches `/usr/bin/ssh … -- <host> python3 -I -u -c '<bootstrap>'`; the bootstrap reads the helper (base64) from the first line of stdin and runs it, the second line is `{"path", "readonly"}`. The helper opens the file (`mode=rw`, never creating it), prints a hello, then answers `execute` and `writable` requests, one JSON line each, values tagged (`{"i"}`, `{"r"}`, `{"b"}`, text, null) so storage classes survive. Lines before the hello (a shell banner) are skipped; after it, an answer without the request's id closes the session. If the helper dies, the request in flight fails and the next one starts a new session. See DECISIONS.md for the safety rules.

**Files.** `GridView` shows 🖼 on `fileColumns` (PocketBase file fields, from `pocketBaseFilesOfTable:`) and, with `detectsFileKeys` (the connection has `s3Bucket`), on values `FileKeysInValue` accepts. A click calls `MainWindowController openFileInGrid:`, which offers a menu when a value holds several files and builds an `ImagePreview` with a loader: `FileS3Fetch` (the connection's bucket, region and `awsProfile`, or PocketBase's S3 settings read from `_params` without its keys, object key `<collection>/<record>/<name>`), or `pocketBaseFileInCollection:…` on the connection's queue (a local read, or the helper's `file` request over SSH; names checked, path kept inside `storage`).

**Values.** Everything is text (`NSString`) or `NSNull`. Postgres params go through `PQexecParams` as untyped text, and Postgres infers the type from the column. SQLite has no such inference for columns without a declared type, so its integers, reals and BLOBs come back as an `NSString` subclass that remembers the storage class and is bound back with it; an edited cell takes the class of the value it replaces (`valueForText:replacing:`). Several statements in one SQLite `execute` run inside a savepoint, all or nothing like one `PQexec`, unless the script manages transactions itself.

**Dropped connection.** If `ssh` dies after the tunnel was established, `SSHTunnel` restarts it on the same port every 2 s and reports the state to the status bar. A query sent during the outage fails. On the next `execute`, `PGConnection` sees `CONNECTION_BAD` and runs `PQreset`. The failed query is not retried, because it may already have written something.

**Editing.** `GridView` keeps changes locally, in three structures:
- `edits`: row → column → new value;
- `deletedRows`;
- `insertedRows`.

Then:
1. `MainWindowController` only allows editing tables with a primary key, which it reads from the structure query.
2. ⌘S turns the changes into SQL with `DBChangeStatements`: DELETE first, then UPDATE, then INSERT, with values as params.
3. Everything runs in one `BEGIN READ WRITE … COMMIT` transaction.
4. Each UPDATE and DELETE must affect exactly 1 row, otherwise everything is rolled back. After an error the changes stay in the grid.

Switching table, page or sort order, closing the window or quitting with unsaved changes asks whether to discard them.

**Production.** A connection marked as production opens with `default_transaction_read_only=on` (Postgres) or `PRAGMA query_only` (SQLite; on a server the helper also refuses pragma writes and `ATTACH`). See DECISIONS.md.

**Language.** Settings stores the choice in the app's `AppleLanguages` default; AppKit picks the matching `.lproj` at launch, so the change applies after a restart, which Settings offers.
