# Decisions

## 2026-10-20 · Swift 6, and design 2a "Soft Glass"

**Context:** the user wanted the app in Swift, together with a new look from Claude Design (direction 2a: rounded floating panels on a soft background, one indigo accent, a roomier grid, spring motion; handoff in Claude Design, project "PlainDB", `design_handoff_plaindb_2a`).
**Decision:** a full rewrite in Swift 6 with strict concurrency, still AppKit with the UI in code and a `Makefile` (`swiftc`), no Xcode project. Behaviour stays as it was; only the presentation follows the design. Values are a `DBValue` enum instead of `NSString`/`NSNull` (SQLite's storage classes are cases instead of an `NSString` subclass), connection info is a `Codable` `Connection` struct that reads the plists of earlier versions, errors are thrown. libpq is imported through a module map. Tests link against the app's code built once as a library.
**What the design changed:**
- the window: no split view and no toolbar items; three panels (sidebar, content, inspector) on the window background, the top row (connection pill, sliding tabs, PRODUCTION) in the title bar's area, the traffic lights in the sidebar's first row;
- the sidebar selection is one pill sliding between rows; the tabs and the inspector's Tree / Text have a sliding thumb;
- the grid: 34 pt rounded rows inset from the panel, Geist Mono, sort ascending → descending → off;
- Structure as cards instead of grids; the diagram on a dot grid, Reset Layout springs back;
- the JSON inspector is its own panel animating its width; the foreign key preview is a card (`CardPopover`), not an `NSPopover`;
- the production confirmation is drawn over the window (scrim, the SQL, Run in Transaction) instead of an `NSAlert`, and a toast reports the saved rows; the production frame is 2 pt;
- a light / dark button in the window, remembered; Reduce Motion turns the motion into short fades.
**Consequences:** the Connections and Settings windows weren't in the design; they keep their layout in the same visual language. Supersedes "Objective-C, AppKit, UI in code, Makefile" (2026-10-15) and the window parts of "Design from Claude Design, mapped to native AppKit".

## 2026-10-15 · Objective-C, AppKit, UI in code, Makefile

**Context:** a tool for one person on one Mac. It should be simple and pleasant to use.
**Decision:** native AppKit in Objective-C. UI built in code, build via `Makefile`, no `.xcodeproj`.
**Consequences:** every change is a readable diff in a `.m` file, and the build is one command. No Interface Builder preview. Debug with `lldb` or Xcode's "Debug Executable".

## 2026-10-15 · Postgres first, SQLite later

**Context:** connecting to the production Postgres matters most.
**Decision:** v0.1 supported Postgres only. The `DBConnection` protocol left room for a `SQLiteConnection`, which came next (see "SQLite files").

## 2026-10-16 · File previews from S3 and PocketBase storage

**Context:** rows point to files kept elsewhere: fleet's Postgres stores PocketBase-style S3 keys (`pbc_…/<record>/<name>`, a `text[]` of them for several photos), PocketBase file fields hold bare names, the objects live in S3 or `pb_data/storage`.
**Decision:** a 🖼 badge on PocketBase file fields and, when a connection has an S3 bucket, on values that look like file keys (a `/`, a known extension, no surrounding whitespace; arrays and JSON lists all-or-nothing). Downloads go through the user's `aws` CLI and profile into memory: no AWS secrets in PlainDB, SSO works, no temporary files; PocketBase's own S3 access keys in `_params` are never read. Without S3, PocketBase storage is read next to the database or by the SSH helper, names restricted to PocketBase's alphabet and the resolved path kept inside `storage`. Images and PDFs preview in the existing popover; other files can be saved where the user chooses.
**Not included:** files the application encrypted itself (fleet's `files.file_key_encrypted`), uploads, other clouds, presigned URLs.
**Keeping it from leaking** (asked for by the user): previews live in memory only; every copy PlainDB makes (`TBCopyLocally`: cells, rows, images, and the SQL / JSON text views through `LocalCopyTextView`) goes to the pasteboard for this host only (no Universal Clipboard) with the nspasteboard.org Concealed and Transient markers; Save As… on production asks first. Screen-capture blocking and turning off window restoration were offered and not wanted. Errors name the cause (no access with the profile, no such object, no credentials, storage path and permissions) instead of aws's raw text.
**Design:** the S3 row in the connection form and the file popover have no design yet; they reuse the form's field style and the image popover.

## 2026-10-16 · Design sections 7 and 8

**Decision:** follow the new design for the diagram (220 pt boxes, 34 pt gaps, neighbours top-aligned, "‹ Cała baza", Reset Layout in neighbours mode too, box and secondary-ink tokens `Theme.box` / `text3`), the schema sheets, SQL completion (geometry, "⌃Space: suggestions" hint, ←/→ close the list), tabs ("+" and ⌘T through `newWindowForTab:`, tab tooltips, "⌘-click" hint), the Files tab (inset card, drop overlay, footer, "Frame Colour" submenu, missing files in red), the connection button (24 pt icon) and the SQLite-over-SSH form.
**Choices made with the user:**
- Sheet SQL is laid out as in the design (one clause per line, `;`), but keeps quoted, schema-qualified names and the explicit constraint name, so any name works and the statement says exactly what runs.
- The Files tab keeps opening a file on a single click (the design selects first).
- A table picked in the sidebar while the Diagram is shown opens its data, as in the design.
- Frame colours stay as they are (they match the connection form's design); the Files design's slightly different hexes weren't taken.

## 2026-10-16 · SQLite on a server, over SSH (production PocketBase)

**Context:** the user wants to browse and sometimes fix data in a production PocketBase (`pb_data/data.db`) on servers they reach over SSH, PocketBase running as a binary on some and in Docker on others. An SQLite file has no port to tunnel to; SSHFS and other network file systems break SQLite's locking next to a running PocketBase; the `sqlite3` CLI prints no column names for an empty result and would need params pasted into SQL.
**Decision:** a small Python helper (`Resources/sqlite_remote.py`, stdlib only) runs on the server next to the file and answers JSON lines over one long-lived `ssh` session. `SQLiteConnection` keeps all SQLite knowledge and only hands statements to `RemoteSQLite` instead of `libsqlite3`, so the grid, editing, ⌘F, PocketBase relations, diagram, SQL and production mode work unchanged. Docker: the host path of the volume, not `docker exec` (Alpine images have no Python).
**Safety:**
- ssh as for tunnels: `BatchMode` (keys or the agent, no stored secret), `known_hosts` as configured, `--` before the host, timeouts.
- The remote command is a constant (`python3 -I -u -c '…'` reading the helper from stdin); the helper, the path and the read-only flag travel on stdin, so nothing from the user reaches the remote shell (fish would even interpret `\` inside single quotes). `-I` keeps planted modules in the remote home out.
- Read-only is enforced by the helper on the server: `query_only`, plus an authorizer refusing `ATTACH` (and so `VACUUM INTO`) and any pragma that sets something (`query_only` itself, `journal_mode`, which `query_only` alone allows). Only the request sent after the user confirmed a write lifts it, and the helper restores it as soon as that transaction ends, even mid-script. Prepared statements aren't cached, so one prepared while writable can't skip the check later.
- Answers must carry the request's id; anything unexpected closes the session instead of being guessed at.
**Consequences:** needs `python3` (3.6+) on the server. Writes bypass PocketBase's hooks and validation, as editing the local file always did. Schema queries use `sqlite_master` and one query per kind for the whole database (pragma table-valued functions joined with `sqlite_master`), because servers' SQLite can be older than 3.33 and every query is a round trip. Local read-only files still rely on `query_only` alone.
**Rejected:** PocketBase through its HTTP API with a superuser: no SQL tab, a superuser token can't be made read-only, and SSH covers the need.

## 2026-10-15 · PocketBase relations

**Context:** PocketBase files have no SQL foreign keys: relations are described in `_collections` (JSON fields, `fields` in v0.23+, `schema` before), and a relation column holds a record id, or a JSON array of ids for multi relations. The diagram showed no arrows.
**Decision:** `SQLiteConnection` reads those relations. Single ones are returned as foreign keys (grid ↗, picker, ⌘F through keys, diagram); multi ones only reach the diagram, as dashed arrows (`allForeignKeys`' seventh column "many"), since their values aren't single ids. `managesOwnSchema` turns schema editing off: an `ALTER TABLE` from outside would leave PocketBase's own description behind.
**Rejected (for now):** guessing relations from column names (`user_id` → `users.id`) for databases without keys: a guess can be wrong, and the user didn't ask for it.

## 2026-10-15 · Schema editing from the diagram

**Decision:** "Add Column…" and "Add Foreign Key…" only, from a box's menu. The statement is built by pure functions (`DBAddColumnStatement`, `DBAddForeignKeyStatement`, quoting names; the type and default go in as typed) and always shown before it runs, in a write transaction; on production the sheet is the confirmation. SQLite can't add a foreign key to an existing table, so that item is disabled there with the reason as its tooltip.

## 2026-10-15 · SQL completion

**Decision:** a small completion list of our own under the cursor (not `NSTextView`'s built-in completion window, which can't show a column's type next to its name). What to offer is a pure function (`SQLSuggestionsAt`) working on the text around the cursor: the current statement (between semicolons), aliases from `FROM` / `JOIN` / `UPDATE` / `INTO`, the keyword before the word. No SQL parser: a regular expression and a few rules cover typing; an unusual statement just gets fewer suggestions. The schema is the diagram's (`allColumns`, `allForeignKeys`), read when the SQL tab is first shown and again after `CREATE` / `ALTER` / `DROP` / `RENAME` run from the editor.

## 2026-10-15 · Schema diagram

**Decision:**
- A Diagram tab next to Data / Structure / SQL. The schema of the whole database comes from two queries (`allColumns`, `allForeignKeys`) instead of one per table.
- Layout without a library: a table's column is one more than the highest column of the tables it references (cycles and self-references broken), each column ordered by where its connected tables are (two sweeps). Simple, deterministic and fast enough for hundreds of tables; it's a pure function with its own test.
- One view draws all boxes and arrows (like the grid cells), inside a magnifiable scroll view.
- Opening a table is never automatic: a click selects, a double-click shows neighbours, "Open Table" / "Open in New Tab" are explicit.
- Dragged positions are remembered per connection (user defaults) for the whole-database view; neighbours are always laid out fresh.

**Rejected:** a force-directed layout (moves every time, hard to test); a graph library (a dependency for a few hundred lines).

## 2026-10-15 · Table tabs

**Decision:**
- Native window tabs, on request only ("Open in New Tab", ⌘-click); a plain click keeps replacing the window's table.
- Tabs share the connection and tunnel: no second login, tunnel or Keychain prompt. The connection's serial queue orders work from all tabs, and a write transaction is one queued block, so tabs can't interleave inside it. The connection closes with its last window.
- Open tabs are restored when the connection is opened again, never at launch: a production database isn't contacted unless the user opens it. Closing a whole window closes its tabs one by one in one event, so saving waits a run-loop turn and keeps the full list when nothing is left.

**Rejected:** a custom tab bar inside the window (more code, and it wouldn't behave like other Mac apps); a new connection per tab (logins, tunnels, Keychain prompts).

## 2026-10-15 · SQLite files

**Decision:**
- A second `DBConnection`, `SQLiteConnection`, on the system `libsqlite3` (no new dependency). The schema is always `main`, hidden in names like `public`.
- What the window used to write in Postgres SQL moved behind the protocol first: time limits (Postgres `SET statement_timeout`, SQLite a progress handler with a deadline; both report sqlstate `57014`), write transactions (`BEGIN READ WRITE` / `PRAGMA query_only = OFF; BEGIN`), emptying a table (`TRUNCATE` / `DELETE`) and boolean literals (`t`/`f`, `1`/`0`).
- `$1`, `$2` … are bound by name: SQLite numbers parameters in order of first appearance, so a statement using `$2` before `$1` would bind wrongly by position.
- Search uses a registered `plaindb_like` (LIKE on case-folded Unicode); SQLite's own `LIKE` folds ASCII only. User SQL keeps the standard `LIKE`.
- Read-only files use `PRAGMA query_only`, refused writes report sqlstate `25006`, so the production confirmation works unchanged.
- BLOBs are shown as `\x` hex, the form of Postgres `bytea`, so image detection works for both.
- Values keep their SQLite storage class (integer, real, BLOB) through display and editing; binding everything as text broke saving in columns without a declared type (`WHERE id = '5'` doesn't match the integer 5) and turned edited numbers into text.
- Several statements in the SQL tab run in a savepoint, so a failing second statement doesn't leave the first one applied (Postgres does the same in one `PQexec`).
- PlainDB never creates a database file: a missing path is an error.
- Declared types map to kinds case-insensitively (`BOOLEAN`, `DATE`, `DATETIME`); values that don't parse as dates are edited as text.

**Rejected for now:** editing tables without a primary key through `rowid`; creating files, `ATTACH`, SQLCipher.

## 2026-10-15 · Tunnel through the system `ssh`, not libssh2

**Decision:** `NSTask` runs `/usr/bin/ssh -N -L` with `BatchMode=yes`, `ExitOnForwardFailure=yes` and `ServerAliveInterval=30`.
**Consequences:** `~/.ssh/config`, the agent, `ProxyJump` and hardware keys work for free. SSH passwords are not supported, because there is no terminal. If the app crashes, the `ssh` process may be left orphaned.

## 2026-10-15 · Production protection enforced by the database

**Context:** an accidental `UPDATE` on production must be impossible without confirmation.
**Decision:** the production session has `default_transaction_read_only=on`, so Postgres itself rejects writes (SQLSTATE 25006). The app catches that error, shows the SQL for confirmation (Enter = Cancel) and runs it inside `BEGIN READ WRITE … COMMIT`.
**Rejected:** guessing from the first word of the query. Too easy to get around, e.g. `SELECT 1; DELETE …` or `WITH … DELETE`.

## 2026-10-15 · Schema from `pg_catalog`, not `information_schema`

**Reason:** `information_schema.table_constraints` hides constraints from users who only have `SELECT`. On production we often connect with exactly that kind of account.

## 2026-10-15 · Local databases without configuration

**Context:** we want to click local databases like in Postgres.app, without creating a connection for each.
**Decision:** the "Local" tab connects to the default libpq server (socket in `/tmp`, port 5432, OS user, database `postgres`) and lists `pg_database`. A click opens a connection without saving it.
**Consequences:** servers on other ports or with a password have to be added in the "Saved" tab.

## 2026-10-15 · Editing: changes collected locally, saved in one transaction

**Decision:**
- Edits don't go to the database right away. They collect in the grid and are saved with ⌘S.
- Only tables with a primary key are editable, because `WHERE` is built from the original key values.
- Each UPDATE and DELETE must affect exactly 1 row, otherwise `ROLLBACK`. This protects against overwriting a row someone else deleted or re-keyed in the meantime.
- On production, a SQL preview with inlined values is shown before saving. The preview is display-only; execution always uses params.

**Consequences:**
- An empty cell means an empty string. NULL is set from the context menu.
- Tables without a primary key are read-only. SQLite could use `rowid` here.

## 2026-10-15 · Grid cells draw themselves

**Context:** big tables stuttered. Measured with `make perf` (200 rows × 30 columns of realistic values): 13 ms per vertical step, 18 ms per horizontal step (two thirds of frames dropped), 250 ms to load a page, 144 MB for the grid.
**Findings:**
- Each cell was an `NSTextField` with its own layer, backing store and constraints: about 900 of them.
- A view-based `NSTableView` keeps views for every column of a visible row, and AppKit redraws the whole row (about 6000 pt) on every sideways scroll step. That was 930 cell redraws per step, 80% of them for cells off screen.
- The typesetter's truncation (`NSStringDrawingTruncatesLastVisibleLine`) took most of the remaining drawing time.

**Decision:**
- `GridCellView` draws its fill, text and ring in `drawRect:`, with no text field and no constraints.
- Cells off screen return early. `GridView` redraws cells whose column scrolls into view.
- The ellipsis is cut arithmetically, since cells use monospaced fonts.
- Column widths use the measured character width.
- Cell editing uses a text field that exists only while editing.

**Result:** 3 ms vertical, 6 ms horizontal, 50 ms per page, 23 MB; CPU per scroll step down from 16.5 to 4.5 ms. `make perf` fails above 8.3 ms per step (120 Hz) or 100 ms per page.

## 2026-10-15 · JSON inspector

**Context:** JSON cells with many values are unreadable in a grid cell. No design was supplied for this.
**Decision:**
- Double-click or Enter on a cell holding a JSON object or array opens a native inspector panel (trailing `NSSplitViewItem`) instead of inline editing.
- The panel has a Tree / Text switch. Edits are validated live. Apply stores the minified value as a normal pending change, saved with ⌘S (with the production confirmation).
- The panel is read-only for tables without a primary key and for SQL results.
- Formatting and the tree use a small parser of our own, because `NSJSONSerialization` loses key order, and for `json` columns (unlike `jsonb`) the order is part of the stored text. `NSJSONSerialization` is only used to validate and to unescape strings.

## 2026-10-15 · Find (⌘F) searches the whole table

**Context:** a page holds 200 rows, so searching only what is loaded would miss most of a big table.
**Decision:**
- The Data tab's find bar filters on the server: `WHERE col1::text ILIKE $1 OR col2::text ILIKE $1 …` over all columns. The term goes in as a parameter, with `%`, `_` and `\` escaped so they match literally. Results page and sort as usual, and matches are highlighted in the cells.
- One query per Enter, not per keystroke.
- Each search runs with `statement_timeout = 15 s`, since it scans every column of the whole table. On a big production table it stops with a hint instead of blocking the connection.
- The condition comes from the connection (`searchConditionForColumns:`), so SQLite can supply its own syntax later.
- Foreign keys are searched too, one level deep: `driver_id IN (SELECT id FROM drivers WHERE <any column matches>)` for every single-column key (`DBSearchCondition`, tested in `pg_test`). A claim is found by its driver's name. Such rows don't contain the term themselves, so a second small query (only the key values on the page) marks the key cells whose referenced row matched. Always on: a switch would only matter for a huge referenced table, and the 15 s limit already covers that.

## 2026-10-15 · Switching database or connection from the window

**Decision:** the connection name and target at the left of the toolbar (as in the design) open a menu: databases on the same server (`pg_database` through the current connection, so it works over SSH too), saved connections, Connections…. A choice opens the new connection with the same code as the Connections window (`TBConnect` in `Connector.m`). That window replaces the current one in place, after the unsaved-changes prompt; the old window closes with its tunnel.
**Rejected:** swapping the connection inside the same window. Every piece of per-connection state (tables, pins, grids, inspector, tunnel, production frame and badge) would have to be reset by hand.

## 2026-10-15 · Row counts

**Decision:**
- The sidebar shows the planner's estimate (`pg_class.reltuples`), which is free to read even on huge tables.
- The open table gets an exact `count(*)` (with the active search's `WHERE`) after its page loads, under a 3 s `statement_timeout`. If that times out, the pager shows "of ~estimate". When everything fits on one page the pager shows only `1–20`, as in the design.

## 2026-10-15 · Emptying a table

**Decision:**
- Right-click → "Empty Table…" runs `TRUNCATE`, but only after the table name is typed. The name is shown with a Copy button, and Enter cancels.
- The confirmation is a custom sheet laid out as in the design: warning icon beside the title and what will happen (with the estimated row count), then the name, the field, and "Empty" (red text, dimmed until the name matches) next to the default "Cancel". `NSAlert` centres its content and can't put the icon beside the text.
- It runs in `BEGIN READ WRITE … COMMIT`, so it also works on a read-only production session.
- No `CASCADE`: if other tables reference this one, Postgres refuses and says so, rather than emptying them too.

## 2026-10-15 · Foreign keys: preview and picker

**Decision:**
- Single-column foreign keys are read from `pg_constraint`; composite keys are ignored.
- Values get a ↗ badge (a 15 pt accent-tinted square right after the value, as in the design) that opens the referenced row in a popover, with Open Table.
- Editing such a cell opens a picker instead of a text field. It searches the referenced table across all columns: an empty term lists the first rows; otherwise the same `ILIKE` condition as ⌘F, `LIMIT 20`, 3 s timeout. Each result shows its key plus a few non-empty values, and the picked key becomes a normal pending edit.

## 2026-10-15 · Image values

**Decision:**
- Detection only looks at the start of a value: bytea magic numbers (PNG, JPEG, GIF, WebP, TIFF), `data:image/`, base64 of those, and http(s) URLs with an image extension. It is cheap enough for every drawn cell (`make perf` includes it).
- Double-click or the 🖼 badge opens a preview popover.
- URLs are downloaded only on that click, with an ephemeral session, never in the background.

## 2026-10-15 · Booleans and dates edited with controls

**Decision:**
- Column types from the structure query map to kinds (`TBKindForType`).
- Booleans show a checkbox (drawn by the cell as in the design; NULL gets an empty one) and "true"/"false" instead of `t`/`f`. A click on the checkbox, double-click or Enter toggles; NULL toggles to true, and Set NULL is in the context menu.
- Date/time kinds open a popover with a calendar plus a precise text-and-stepper field; `time` gets only the field. The calendar is a small view of its own (`CalendarView`), because `NSDatePicker`'s graphical style can't take the design's look. The field uses the `sv_SE` locale, which writes dates as `2026-10-03 10:20:29`, like Postgres.
- `date`, `time` and `timestamp` have no time zone, so they are handled in UTC and round-trip exactly, also across DST changes. `timestamptz` is shown in the local zone and written with its offset.
- Picking the same moment written differently (`+02` vs `+02:00`) isn't recorded as a change. Fractional seconds are dropped when a value is edited this way (`date_test`).

## 2026-10-15 · Window colours for every connection

**Decision:** any connection can have a frame colour, stored as `frame`; local databases keep theirs in user defaults by name. Production always has one (red by default) and also the badge. Older entries carried `color` on every connection, although it only applied to production. So `frame` falls back to `color` for production connections only, and other connections don't suddenly get a red frame (`ConnectionStore frameColorFor:`, tested in `store_test`).

## 2026-10-15 · Pinned tables

**Decision:** right-click a table to pin it to a "Pinned" section at the top of the sidebar, in pin order. Pins are stored in user defaults, keyed by connection id and database. Rebuilding the list keeps the open table selected without reloading it.

## 2026-10-15 · Slim scroll bars

**Decision:** grids use `ThinScroller`, an 11 pt track in the header colour with a 7 pt rounded knob, close to the design's grid scroll bar. It is always visible (classic style) when there is something to scroll. No setting for it yet.

## 2026-10-15 · App icon

**Decision:** `Resources/AppIcon.icns`, made from the supplied "Neumorphic Database Icon" PNG (it replaced the first, "Minimal Database App Icon"): the dark rounded square cut out of its white background, scaled to the macOS icon grid (824 pt body on a 1024 pt canvas) and masked with continuous corners, so the corners are transparent and newer macOS doesn't put it in a grey frame.

## 2026-10-15 · Values as text

**Decision:** every value is read and sent as text or `NULL`.
**Consequences:** one way to display and edit all types. `bytea` shows up as hex.

## 2026-10-15 · MIT License

**Decision:** PlainDB is fully open source under MIT: anyone may use, modify and redistribute it, commercially too, keeping the copyright notice.
**Rejected:** GPL, which would require derived apps to be open as well; public-domain dedications (Unlicense, 0BSD), which aren't recognised everywhere and are rarer in practice.

## 2026-10-15 · Repository in English

**Decision:** commits, README, docs and code comments are in English.

## 2026-10-15 · Renamed to PlainDB

**Decision:** the app is called PlainDB (bundle id `com.addxrall.plaindb`, `~/Library/Application Support/PlainDB`, Keychain service `PlainDB`).
**Consequences:** connections and passwords saved under the old name (Tabula) are read as a fallback and moved over on the next save, so nothing is lost. The GitHub repo and the local folder still use the old name.

## 2026-10-15 · UI in English and Polish, chosen in Settings

**Decision:** native localization. UI strings are English keys in code (`L()`), Polish in `pl.lproj/Localizable.strings`, plurals in `.stringsdict` files so Polish gets its one / few / many forms from the system. Settings writes the app's `AppleLanguages` and offers a restart.
**Rejected:** switching the language live without a restart: every view would have to rebuild its strings, for a setting changed once.
**Consequences:** `tests/check_strings.py` keeps the translation complete and the format specifiers in sync. Error messages coming from Postgres stay in the server's language.

## 2026-10-15 · Design from Claude Design, mapped to native AppKit

**Context:** the design (Claude Design project "Tabula") is HTML; the app is AppKit.
**Decision:** take its layout, colours (as `Theme` tokens, light and dark), typography (SF Mono for data), states and texts. Use native equivalents where they exist:
- sidebar via `NSSplitViewController`;
- title, subtitle and tabs in a unified toolbar;
- source-list sidebar selection;
- `NSAlert` with a highlighted SQL accessory view as the production sheet.

**Production indicator** (design update, same day): no banner across the content. The right side of the toolbar shows a "PRODUCTION" badge in the connection's frame colour with "read-only, writes need confirmation" next to it. The frame colour is one of 8 presets or any colour from the system colour panel (custom swatch), stored as a hex string in the connection.

**Production frame:** as in the design, a 3 pt ring around the whole window, above everything, following the rounded corners. It is a border on the window's root view layer, with the layer's corner radius set to the window's (16 pt with a unified toolbar, read from the private `_cornerRadius`). A first version framed only the content area; that was wrong.

**Scroll bars:** grids always use classic scroll bars (`NSScrollerStyleLegacy`), so a wide table has a horizontal bar you can see and grab, as the design's grid has. Overlay scroll bars appear only while scrolling.

**New features section** (design update): the features first built without a design (JSON inspector, foreign keys, images, booleans and dates, find, pins and row counts, emptying a table, switcher, Settings) were drawn in the design afterwards, and the app follows it: badges and checkboxes drawn in the grid cells, a 250 pt find field with a hint, the match count and an accent magnifier button (`TBToolButton`), popovers at the design's sizes, the switcher menu with ✓, colour dots and the address on the right, and the design's Polish wording ("Opróżnij tabelę…", "Przypnij na górze").

**Deviations:**
- The connections window keeps the Local / Saved switch, which the design predates.
- Badges don't turn solid accent on hover: that would need mouse tracking over every grid cell.
