# PlainDB's helper for SQLite databases on a server. PlainDB starts it over ssh with a constant command,
#   python3 -I -u -c 'import sys,base64;exec(base64.b64decode(sys.stdin.readline()))'
# and sends this file (base64) as the first line of stdin, then a JSON config line {"path": ..., "readonly": ...}.
# Nothing is written to the server apart from SQLite's own files next to the database.
#
# Protocol: one JSON object per line each way. After opening the database it prints {"hello": "plaindb", ...}
# (or {"error": ...} and exits). Requests:
#   {"id": n, "op": "execute", "sql": "...", "params": [...], "timeout": seconds}
#   {"id": n, "op": "writable", "on": true}
#   {"id": n, "op": "file", "collection": "...", "record": "...", "name": "...", "max": bytes} → {"id": n, "data": "<base64>"}
# Answers: {"id": n, "columns": [...], "rows": [[...]], "affected": n} or {"id": n, "error": "...", "code": ...}.
# Values: null, a string (TEXT), {"i": "<integer>"}, {"r": "<real as SQLite prints it>"}, {"b": "<base64>"}.
#
# Read-only (production) connections are guarded here, on the server: query_only, plus an authorizer refusing
# ATTACH (and so VACUUM INTO) and any pragma that sets something. Only the "writable" request, sent after the
# user confirmed a write, lifts it, and only until that transaction ends. Needs Python 3.6+, stdlib only.

import base64
import json
import os
import re
import sqlite3
import sys
import threading
from urllib.parse import quote

# pragmas that take an argument but only read
READ_PRAGMAS = {"table_info", "table_xinfo", "index_list", "index_info", "index_xinfo", "foreign_key_list",
                "foreign_key_check", "integrity_check", "quick_check"}
TRANSACTIONAL = re.compile(r"\b(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|END\s+TRANSACTION)\b", re.I)
ONLY_COMMENTS = re.compile(r"^(\s|--[^\n]*(\n|$)|/\*.*?\*/)*$", re.S)


class State:
    readonly = False  # a production connection
    writable = False  # the user confirmed a write; until the transaction ends
    internal = False  # the helper itself changes query_only


state = State()


def authorize(action, arg1, arg2, database, source):
    if not state.readonly or state.writable or state.internal:
        return sqlite3.SQLITE_OK
    if action == sqlite3.SQLITE_ATTACH:
        return sqlite3.SQLITE_DENY
    if action == sqlite3.SQLITE_PRAGMA and arg2 is not None and (arg1 or "").lower() not in READ_PRAGMAS:
        return sqlite3.SQLITE_DENY
    return sqlite3.SQLITE_OK


def set_query_only(con, on):
    state.internal = True
    try:
        con.execute("PRAGMA query_only = " + ("ON" if on else "OFF"))
    finally:
        state.internal = False


def end_write(con):
    state.writable = False
    set_query_only(con, True)


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def like(value, pattern):
    """plaindb_like: LIKE ignoring case for all of Unicode, with \\ escaping % and _."""
    if value is None or pattern is None:
        return None
    value, pattern = str(value).casefold(), str(pattern).casefold()
    out, i = [], 0
    while i < len(pattern):
        c = pattern[i]
        if c == "\\" and i + 1 < len(pattern):
            out.append(re.escape(pattern[i + 1]))
            i += 2
            continue
        out.append(".*" if c == "%" else "." if c == "_" else re.escape(c))
        i += 1
    return 1 if re.fullmatch("".join(out), value, re.S) else 0


def decode(v):
    if isinstance(v, dict):
        if "i" in v:
            return int(v["i"])
        if "r" in v:
            return float(v["r"])
        if "b" in v:
            return base64.b64decode(v["b"])
    return v


def encode(con, v):
    if v is None or isinstance(v, str):
        return v
    if isinstance(v, int):
        return {"i": str(v)}
    if isinstance(v, float):  # as SQLite prints it, so it reads like a local file
        return {"r": con.execute("SELECT CAST(? AS TEXT)", (v,)).fetchone()[0]}
    return {"b": base64.b64encode(bytes(v)).decode("ascii")}


def statements(sql):
    """The script's statements; a trailing piece without ; counts unless it's only whitespace or comments."""
    out, start = [], 0
    for i, c in enumerate(sql):
        if c == ";" and sqlite3.complete_statement(sql[start:i + 1]):
            out.append(sql[start:i + 1])
            start = i + 1
    rest = sql[start:]
    if not ONLY_COMMENTS.match(rest):
        out.append(rest)
    return [s for s in out if not ONLY_COMMENTS.match(s.rstrip(";"))]


def error_code(e):
    message = str(e)
    if "interrupted" in message:
        return "interrupted"
    if "readonly" in message or "not authorized" in message or "authorization denied" in message:
        return "readonly"
    return None


def execute(con, request):
    params = {str(i + 1): decode(p) for i, p in enumerate(request.get("params") or [])}
    sql = request["sql"]
    parts = statements(sql)
    timer = None
    if request.get("timeout"):
        timer = threading.Timer(request["timeout"], con.interrupt)
        timer.start()
    batch = len(parts) > 1 and not con.in_transaction and not TRANSACTIONAL.search(sql)
    last = None
    try:
        if batch:
            con.execute("SAVEPOINT plaindb_batch")
        for part in parts:
            was_in_transaction = con.in_transaction
            names = re.findall(r"\$(\d+)", part)
            cursor = con.execute(part, {n: params.get(n) for n in names} if names else ())
            columns = [d[0] for d in cursor.description] if cursor.description else []
            rows = cursor.fetchall()
            result = {"columns": columns, "rows": [[encode(con, v) for v in row] for row in rows],
                      "affected": -1 if columns else con.execute("SELECT changes()").fetchone()[0]}
            if columns or last is None or not last["columns"]:
                last = result
            if state.readonly and state.writable and was_in_transaction and not con.in_transaction:
                end_write(con)  # the confirmed transaction is over, whatever follows in the script
        if batch:
            con.execute("RELEASE plaindb_batch")
    except Exception:
        if batch:
            try:
                con.execute("ROLLBACK TO plaindb_batch")
                con.execute("RELEASE plaindb_batch")
            except sqlite3.Error:
                pass
        raise
    finally:
        if timer:
            timer.cancel()
    return last or {"columns": [], "rows": [], "affected": 0}


FILE_NAME = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]*$")


class FileProblem(Exception):
    """Why a storage file can't be read: a code PlainDB words in the user's language, and the path concerned."""

    def __init__(self, code, path=""):
        super().__init__(code)
        self.code, self.path = code, path


def read_file(path, request):
    """A file from PocketBase's storage next to the database: pb_data/storage/<collection>/<record>/<name>."""
    names = [request.get("collection"), request.get("record"), request.get("name")]
    if not all(isinstance(n, str) and len(n) < 256 and FILE_NAME.match(n) for n in names):
        raise FileProblem("badname")
    storage = os.path.join(os.path.dirname(os.path.realpath(path)), "storage")
    if not os.path.isdir(storage):
        raise FileProblem("nostorage", storage)
    storage = os.path.realpath(storage)
    wanted = os.path.join(storage, *names)
    for folder in (storage, os.path.join(storage, names[0]), os.path.join(storage, names[0], names[1])):
        if os.path.isdir(folder) and not os.access(folder, os.R_OK | os.X_OK):
            raise FileProblem("permission", folder)
    file = os.path.realpath(wanted)
    if not file.startswith(storage + os.sep):
        raise FileProblem("badname")
    if not os.path.isfile(file):
        raise FileProblem("notfound", wanted)
    if not os.access(file, os.R_OK):
        raise FileProblem("permission", file)
    if os.path.getsize(file) > int(request.get("max") or 0):
        raise FileProblem("toobig", file)
    with open(file, "rb") as f:
        return {"data": base64.b64encode(f.read()).decode("ascii")}


def main():
    config = json.loads(sys.stdin.readline())
    state.readonly = bool(config.get("readonly"))
    try:
        # mode=rw: never creates a file; a missing one is an error
        con = sqlite3.connect("file:" + quote(config["path"]) + "?mode=rw", uri=True, timeout=3,
                              isolation_level=None, check_same_thread=False, cached_statements=0)
        con.text_factory = lambda b: b.decode("utf-8", "replace")
        con.execute("SELECT count(*) FROM sqlite_master").fetchall()  # fails for files that aren't databases
        con.execute("PRAGMA foreign_keys = ON")
        con.create_function("plaindb_like", 2, like)
        con.set_authorizer(authorize)
        if state.readonly:
            set_query_only(con, True)
    except Exception as e:
        send({"error": str(e)})
        sys.exit(1)
    send({"hello": "plaindb", "version": 1})

    for line in sys.stdin:
        request = json.loads(line)
        answer = {"id": request.get("id")}
        try:
            if request.get("op") == "writable":
                if request.get("on"):
                    state.writable = True
                    set_query_only(con, False)
                elif state.readonly:
                    end_write(con)
                else:
                    state.writable = False
                answer.update({"columns": [], "rows": [], "affected": 0})
            elif request.get("op") == "file":  # reading only, so allowed on read-only connections too
                answer.update(read_file(config["path"], request))
            else:
                answer.update(execute(con, request))
        except FileProblem as e:
            answer.update({"error": e.code, "code": e.code, "path": e.path})
        except Exception as e:
            answer.update({"error": str(e), "code": error_code(e)})
        send(answer)


main()
