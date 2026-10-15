# PlainDB

A small, native Postgres client for macOS, written in Objective-C and AppKit. For quickly looking at what a database contains and fixing a value here and there. Everything runs locally: no accounts, no cloud. The interface is available in English and Polish.

## Features

- **Local databases** like in Postgres.app: a grid of databases on the local server, one click connects.
- **Saved connections** with passwords in the Keychain. Production connections get a coloured frame around the window and a "PRODUCTION" badge in the title bar, in one of 8 colours or a custom one.
- **SSH tunnel** through the system `ssh`, so `~/.ssh/config`, keys, the agent and `ProxyJump` just work. The tunnel stays up and reconnects by itself; the status bar shows its state.
- Sidebar with tables and views, with a filter. Right-click a table to **pin** it to the top (remembered per connection and database).
- **Find (⌘F)**: search every column of the whole table (not just the loaded page), ignoring case; matches are highlighted. In the SQL editor ⌘F searches the query text.
- **Data**: 200 rows per page, row numbers, click a header to sort, numbers right-aligned.
- **Editing** (tables with a primary key):
  - double-click or Enter edits a cell, Esc cancels;
  - `+` adds a row, ⌫ deletes or restores the selected rows;
  - right-click gives "Set NULL" and "Copy";
  - changes are highlighted (yellow, green, red), summarised in a bar at the bottom and saved in one transaction with ⌘S.
- **JSON inspector**: double-click a cell holding a JSON object or array to open it in a side panel, as a tree (keys, typed and coloured values, item counts) or as highlighted text you can edit, format and apply. Key order is kept. While the panel is open, clicking another JSON cell shows that one.
- ⌘C copies the selected rows as tab-separated text.
- **Structure**: columns, types, `NOT NULL`, defaults, primary key, indexes.
- **SQL**: editor with syntax highlighting and line numbers; ⌘R runs it, or only the selection.
- **Production mode**: frame and badge in the connection's colour, and a `READ ONLY` session. Writes need confirmation with a SQL preview, then run inside `BEGIN READ WRITE … COMMIT`.
- **Settings** (⌘,): interface language (system, English, Polski).

Planned: SQLite.

## Requirements

- macOS with Xcode or the Command Line Tools
- `libpq` from Homebrew: `brew install libpq`

## Building

```sh
make          # builds build/PlainDB.app
make run      # builds and opens it
make install  # builds and installs to /Applications/PlainDB.app
make test     # Postgres layer, grid and translation checks (PLAINDB_TEST_DB, default: postgres)
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
