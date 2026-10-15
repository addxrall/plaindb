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
| `src/SSHTunnel.m` | `ssh -N -L` via `NSTask`, waiting for the port, reconnecting |
| `src/Connector.m` | `TBConnect`: tunnel (if any) plus database connection in the background, used by the Connections window and the toolbar switcher |
| `src/ConnectionStore.m` | plist in `~/Library/Application Support/PlainDB/connections.plist` and the Keychain (service `PlainDB`); falls back to data saved under the old name `Tabula` |
| `src/UI.h/.m` | design tokens (`Theme`, light and dark), small view helpers, `TBRowView`, `TBCellView` |
| `src/GridView.m` | grid for a `DBResult` (row numbers, numeric alignment, change colours); collects unsaved changes in the Data tab. Cells are `GridCellView`s that draw themselves (see DECISIONS.md, "Grid cells draw themselves") |
| `src/SQLText.m` | SQL text view: highlighting, line number ruler |
| `src/ReferencePopover.m` | foreign key popovers: referenced row preview and the row picker |
| `src/DatePicker.m` | column kinds (bool, date, time, timestamp, timestamptz), Postgres date text ↔ `NSDate`, the date picker popover |
| `src/ImageValue.m` | image detection and decoding for cell values, and the image preview popover |
| `src/JSONInspector.m` | JSON side panel (an `NSSplitViewController` inspector item): tree and text modes; order-keeping JSON parser, pretty-printer and minifier |
| `src/ConnectWindowController.m` | start window: Local tab (grid of databases on the local server) and Saved tab (list, form, production frame colour) |
| `src/MainWindowController.m` | connection window: sidebar, toolbar tabs Data / Structure / SQL, pending changes bar, status bar |
| `src/SettingsWindowController.m` | Settings: interface language |
| `Resources/{en,pl}.lproj` | Polish strings; English and Polish plural rules |
| `tests/pg_test.m` | `PGConnection` and `DBChangeStatements` against a real local Postgres |
| `tests/grid_test.m` | `GridView`: swapping results, change model, ⌫, cell editing, JSON cells opening the inspector |
| `tests/json_test.m` | JSON helpers: formatting keeps key order and string contents, parse tree |
| `tests/store_test.m` | window frame colour rules, including older saved connections |
| `tests/image_test.m` | image detection and decoding (bytea hex, base64, data URI) |
| `tests/date_test.m` | type → kind mapping and date/time round trips, time zones, DST |
| `tests/check_strings.py` | every `L()`/`LN()` key is translated, with matching format specifiers |
| `tests/perf_grid.m` | `make perf`: scroll timing, CPU and memory of the grid on a big page; fails above the 120 Hz frame budget |

## UI structure

The connection window is an `NSSplitViewController` (sidebar + content) in a full-size-content window with a unified toolbar. The window shows the connection name and target as title and subtitle; the centered toolbar item is the Data / Structure / SQL segmented control. Each tab, and each state within a tab (grid / loading / error, SQL idle / running / done / error / result), is a page of a `TBSwitcher`: all pages pinned to its edges with constraints, only the selected one visible. Vertical stacks (`TBColumn`) pin every view's leading and trailing edges explicitly, because `NSLayoutAttributeWidth` alignment leaves views with an intrinsic width narrow and off to one side. Colours come from `Theme`, which resolves light and dark variants dynamically, so a switch of the system appearance needs no reload.

## Flows

**Connecting.** `ConnectWindowController`, on a background thread:
1. Optionally runs `SSHTunnel start`, which waits until `127.0.0.1:<free port>` accepts connections.
2. Calls `PGConnection open`.
3. Calls `onConnected` on the main thread, and `AppDelegate` creates a `MainWindowController`.

**Queries.** Each connection has its own serial queue (`queue`), because `libpq` doesn't support concurrent calls on one connection. `MainWindowController run:done:failed:` dispatches work to that queue and delivers the result and its duration on the main thread. Order is preserved, so when clicking through tables quickly the last click wins.

**Values.** Everything is text (`NSString`) or `NSNull`. Params go through `PQexecParams` as untyped text, and Postgres infers the type from the column.

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

**Production.** A connection marked as production opens with `default_transaction_read_only=on`. See DECISIONS.md.

**Language.** Settings stores the choice in the app's `AppleLanguages` default; AppKit picks the matching `.lproj` at launch, so the change applies after a restart, which Settings offers.
