<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="PlainDB icon">
</p>

<h1 align="center">PlainDB</h1>

<p align="center">
  <b>A small, native Postgres and SQLite client for macOS.</b><br>
  Browse tables, fix a value, run a query. Locally or over SSH, without the clutter.
</p>

<p align="center">
  macOS · Objective-C / AppKit · PostgreSQL · SQLite · English &amp; Polish · MIT License
</p>

<p align="center">
  <img src="docs/screenshot.png" width="820" alt="PlainDB: an orders table on a production connection, with foreign key badges, boolean checkboxes and a JSON value open in the inspector">
</p>

PlainDB is written in Objective-C and AppKit, with no Electron and no web views. It's for quickly looking at what a database contains and fixing a value here and there: follow a foreign key to the row it points to, tick a boolean, pick a date from a calendar, edit a JSON value in a side panel. Everything runs locally: no accounts, no cloud. Production connections are read-only until you confirm a write, and they are framed in a colour you pick, so you always know where you are.

## Features

- **Local databases** like in Postgres.app: a grid of databases on the local server, one click connects.
- **SQLite files**: open with ⌘O, from the Files tab of the Connections window (recent files), by dropping a file on it, or with "Open With" in Finder. The same grid, editing, search and SQL as for Postgres. Mark a file read-only to protect it like a production connection.
- **Saved connections** with passwords in the Keychain. Any connection, local databases included, can have a coloured frame around its window (8 colours or a custom one). Production connections always have one, plus a "PRODUCTION" badge in the title bar.
- **SSH tunnel** through the system `ssh`, so `~/.ssh/config`, keys, the agent and `ProxyJump` just work. The tunnel stays up and reconnects by itself; the status bar shows its state.
- **Switch database or connection** from the window: click the connection name in the toolbar for the other databases on the same server (also over SSH) and your saved connections.
- **Tabs**: right-click a table → "Open in New Tab", or ⌘-click it, to keep several tables of one connection open as native window tabs (a plain click still replaces the current table). Tabs share the connection, and they come back the next time you open that connection.
- Sidebar with tables and views, with a filter and an estimated row count per table. Right-click a table to **pin** it to the top (remembered per connection and database) or to **empty** it (`TRUNCATE`, after typing its name).
- **Foreign keys**: a ↗ next to the value opens the referenced row in a popover. Editing the value opens a search in the referenced table: type a name, pick the row, and its key goes into the cell.
- **Images** stored as `bytea`, base64, `data:` URIs or image URLs get a 🖼; click it to see the picture, its size and dimensions.
- **Typed editing**: booleans show a checkbox that toggles with a click. `date`, `timestamp` and `timestamptz` open a calendar with a precise date and time field (`time` gets just the field); `timestamptz` is shown in your time zone and written with its offset.
- **Find (⌘F or the magnifier)**: search every column of the whole table (not just the loaded page), ignoring case; matches are highlighted and counted. Foreign keys are followed one level: in `claims`, typing a driver's surname finds their claims, and the matching `driver_id` cells are highlighted. In the SQL editor ⌘F searches the query text.
- **Data**: 200 rows per page with the table's total, row numbers, click a header to sort, numbers right-aligned.
- **Editing** (tables with a primary key):
  - double-click or Enter edits a cell, Esc cancels;
  - `+` adds a row, ⌫ deletes or restores the selected rows;
  - right-click gives "Set NULL", "Copy" and "Delete Row" (the whole selection when you right-click inside it; "Restore Row" on deleted rows);
  - changes are highlighted (yellow, green, red), summarised in a bar at the bottom and saved in one transaction with ⌘S.
- **JSON inspector**: double-click a cell holding a JSON object or array to open it in a side panel, as a tree (keys, typed and coloured values, item counts) or as highlighted text you can edit, format and apply. Key order is kept. While the panel is open, clicking another JSON cell shows that one.
- ⌘C copies the selected rows as tab-separated text.
- **Structure**: columns, types, `NOT NULL`, defaults, primary key, indexes.
- **Diagram**: every table with its columns and foreign key arrows, referenced tables on the left. Right-click a table → "Show on Diagram" (or double-click a box) for just its neighbours. Drag boxes (positions are remembered), zoom with a pinch or ⌘+ / ⌘− / ⌘0, export the whole diagram as PNG or PDF. A click only selects a box; open a table from its menu or with "Open Table". From the same menu, "Add Column…" and "Add Foreign Key…" (Postgres) show the exact SQL before running it in a transaction.
- **PocketBase**: open its `pb_data/data.db` and the relations from `_collections` work like foreign keys (↗ previews, picking a record, ⌘F through them, diagram arrows; multi relations are dashed arrows). PocketBase manages its own schema, so schema editing is off there.
- **SQL**: editor with syntax highlighting and line numbers; ⌘R runs it, or only the selection. Completion while typing: tables after `FROM` / `JOIN`, a table's columns after `alias.` or `table.`, otherwise the statement's columns, tables, functions and keywords (↑↓, Tab or Enter, Esc; ⌃Space opens the list).
- **Production mode**: frame and badge in the connection's colour, and a `READ ONLY` session. Writes need confirmation with a SQL preview, then run inside `BEGIN READ WRITE … COMMIT`.
- **Settings** (⌘,): interface language (system, English, Polski).

## Requirements

- macOS with Xcode or the Command Line Tools
- `libpq` from Homebrew: `brew install libpq` (SQLite ships with macOS)

## Building

```sh
make          # builds build/PlainDB.app
make run      # builds and opens it
make install  # builds and installs to /Applications/PlainDB.app
make test     # Postgres and SQLite layers, grid and translation checks (PLAINDB_TEST_DB, default: postgres)
make perf     # grid scroll speed, CPU and memory on a big page (opens a window for a few seconds)
```

## SSH tunnel

Put `user@server` or an alias from `~/.ssh/config` in the **SSH tunnel** field. **Database host** is then the address as seen from the server, usually `localhost`.

PlainDB runs `ssh` in `BatchMode`, so it never asks for a password. You need a key (ideally in the agent), and the server must already be in `known_hosts`. If it isn't yet, connect to it once by hand from a terminal.

## Translations

UI strings are written in English in the code (`L(@"…")`, plurals with `LN(@"%lu rows", n)`). Polish lives in `Resources/pl.lproj/Localizable.strings` and `Localizable.stringsdict`. `make test` fails when a string is missing, unused, or its format specifiers don't match.

## Known limitations

- After each rebuild macOS may ask for Keychain access, because the app's signature changes. Choose "Always Allow".
- The SQL tab loads the whole result into memory. Add a `LIMIT` for huge tables.
- Long-running queries can't be cancelled.

Technical details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Design decisions: [docs/DECISIONS.md](docs/DECISIONS.md).

## License

PlainDB is open source under the [MIT License](LICENSE): use it, change it, ship it, commercially or not. Keep the copyright notice.
