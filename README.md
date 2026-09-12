# drt-db-lib

The generic half of the DRT sqlite connector: the migration runner, row
naming, LIKE escaping, and the schema version. One file, `db.dlua`.

Extracted from discofetch's `api/supervisor.lua`. Nothing in here knows
anything about discofetch: the migration LIST and the database NAME belong to
the program that owns the schema, and only the RUNNER lives here.

## The surface

**Entry points**

    M.new{ db = <handle>, now = <fn () -> unix SECONDS> } -> instance
    instance:migrate(migrations) -> number of versions applied
    instance:schema_version()    -> the highest version applied, or 0

    M.rows_by_name(q)  -> array of name->value maps    (pure)
    M.like_escape(s)   -> s with the LIKE wildcards escaped    (pure)
    M.LIKE_ESCAPE_CHAR -- the character like_escape escapes WITH

**Configurable values**: none per deployment. The four statements the runner
sends are declared once at the top of `db.dlua`, and the table name
`schema_migration` is spelled inside them rather than parameterised — a
program that renamed it would re-run every migration from version 1 against a
populated database.

**Fan-out**: `RUN`, the two kinds of migration statement (a string that must
succeed, a `{ soft = '...' }` that may fail), and `METHODS`, everything an
instance answers to.

This library never opens a handle and never decides what a failed open means.
It receives one. `host.sql.open` is client-side sugar — the name rides along
in each call as `args.db` — so it does not itself touch the disk; the refusal
arrives on the first exec instead, which is why the caller opens and migrates
inside ONE pcall and keeps the connector's own error sentence. And
`create = false` over there means a missing file is refused rather than
conjured: a database has to be created out of band so WAL is set before the
first open, and the authorizer denies PRAGMA to guests permanently, so a
guest program could never fix it afterwards. What to do with that failure —
an honest 503, a crash, a retry — is the caller's decision, so there is no
`db_ready` to capture in here.

## Injected deps

`M.new(deps)` takes exactly two, and a missing or wrong-typed one is a named
failure at `new` rather than a nil call in the middle of a half-applied
migration:

| dep | required | contract |
| --- | --- | --- |
| `deps.db` | yes | an open sql connector handle: a table or userdata with `exec` and `query` functions. This library never opens one. |
| `deps.now` | yes | a zero-argument function returning whole **unix SECONDS**. It is written into `schema_migration.applied_at`, which every other timestamp in a schema is compared against. Never `host.time()` — that answers in milliseconds. |

Two instances over two handles coexist: there is no module-level mutable
state, and the tests assert that no statement crosses between them.

`M.rows_by_name` and `M.like_escape` are plain module fields because they
touch neither the handle nor the clock.

### Deviation from the ownership ruling, stated plainly

The ruling wrote these as `M.migrate(db, migrations, now)` and
`M.schema_version(db)`. They are the same two operations with the same
behaviour; the handle and the clock are named once at construction instead of
at every call, because the module contract these nine libraries share
requires anything reaching db or the clock to arrive through a constructor.
A consumer written against the ruling's spelling needs one line changed:

    local dbx = db.new{ db = handle, now = now }
    dbx:migrate(MIGRATIONS)

## Usage

    local dbx = db.new{ db = host.sql.open(DB_NAME), now = now }

    -- Opening and migrating at startup, but NOT fatally: a crash loop here
    -- takes /health down with it, and then the panel's indicator says
    -- "unreachable", which is the one thing that is definitely not true.
    local ok, err = pcall(function() return dbx:migrate(MIGRATIONS) end)

    -- Migrations are stored PRE-SPLIT. One statement per entry.
    MIGRATIONS = {
      { version = 1, statements = {
          [[CREATE TABLE IF NOT EXISTS account (...) STRICT]],
          [[CREATE INDEX IF NOT EXISTS account_sub ON account (auth0_sub)]],
      } },
      { version = 4, statements = {
          { soft = [[ALTER TABLE fetchpoint ADD COLUMN note TEXT]] },
          [[SELECT note FROM fetchpoint LIMIT 0]],   -- the hard partner
      } },
    }

    local rows = db.rows_by_name(handle.query('SELECT id, name FROM account'))
    local term = '%' .. db.like_escape(q) .. '%'
    -- ... WHERE name LIKE ? ESCAPE '\'      -- db.LIKE_ESCAPE_CHAR

### The two rules the runner is built out of

**Statements are stored pre-split.** The connector prepares exactly one
statement per call, so something has to do the splitting. Doing it at runtime
means stripping `--` comments and then splitting on `;`, which works until the
first migration containing a semicolon or a double dash inside a string
literal, and then cuts a statement in half silently. A Lua array has no such
day. This library will not split a blob for you, on purpose — it refuses a
string `migrations` by name.

**Every soft statement must be followed by a hard one that names the
columns.** Soft exists for exactly one thing: `ALTER TABLE ... ADD COLUMN` has
no `IF NOT EXISTS` form, and the version row is written only after every
statement in a version succeeds — so a version that stops half way re-runs its
earlier statements, and a bare ALTER raises `duplicate column name` on the
second pass. (Measured against build11 and drt 0.5.0: ALTER is permitted by
the authorizer, and it does raise on a re-run.) Soft swallows the error, which
is the risk: an ALTER that failed because the TABLE was missing would be
skipped as silently as one that failed because the column was already there.
So every soft run is followed by a HARD statement naming the columns — a
`SELECT ... LIMIT 0` raises when a column is absent, which turns "silently
skipped" into "loudly wrong" at the one moment somebody can still fix it.
That pairing is the migration list's obligation; this library cannot check it.

**Bootstrap first, version row last.** The runner cannot consult a table it
has not created, so `schema_migration` is created before the done set is read.
There are no transactions — the authorizer denies BEGIN — so a migration can
stop half applied and there is nothing to roll back. Recording the version
last is what makes a re-run converge instead of skipping the rest of a file it
never finished.

### The connector rules every user of this library is obeying

Gathered from the call sites across supervisor.lua rather than from any one of
them, and written here because this is the library whose whole subject is the
connector:

* **No transactions.** BEGIN is denied. Multi-statement writes are ordered to
  survive being interrupted between any two of them, and a single statement is
  the only consistency available.
* **Check-and-claim, never SELECT-then-INSERT.** Draw, insert, and let a
  PRIMARY KEY or a UNIQUE refuse the duplicate — that constraint IS the
  atomicity. For an update, put the precondition in the WHERE and read
  `changes` to learn whether WE moved the row.
* **Nil binds are refused outright** ("SQL NULL is spelled NULL in the
  statement text"). An optional column is ABSENT FROM THE STATEMENT — built
  into the column list and the placeholders only when there is a value —
  rather than bound as nil. `rows_by_name` answers in the same shape on the
  way back: a NULL column is an absent key.
* **No PRAGMA, ever.** Denied permanently, so nothing here can tune the file
  it was handed.
* **`db.try_exec` is the non-raising exec** and is what check-and-claim is
  written against. `migrate()` deliberately does NOT use it: it wraps its soft
  statements in `pcall(db.exec, ...)` so the only swallowed error in this
  library is the one the soft/hard discipline accounts for. That is a choice,
  and a test counts `try_exec` calls to keep it one.

## Dependency edges

**None.** This library depends on nothing else in the set — it is the floor,
alongside `drt-http-api-lib`, `token-bucket-lib` and `discofetch-model-lib`.

Its consumers:

* `discofetch-db-lib` — owns `DB_NAME` and `MIGRATIONS` (the statement list
  moves verbatim, whitespace inside every `[[...]]` included, because
  `api/migrations/*.sql` is the readable source it must keep pairing with) and
  calls `migrate` and `schema_version` through this library.
* `discofetch-accounts-lib` and `discofetch-fetchpoint-lib` — `rows_by_name`.
* `like_escape` — the fetchpoints search and the admin account search.

## Known, carried over

Behaviour left exactly as it is in `supervisor.lua`, including where I think
it is wrong. Each has a test pinning the current behaviour.

1. **A `{ soft = ... }` table with an absent or misspelled key is a silent
   no-op.** `pcall(db.exec, nil)` swallows the refusal, the version applies
   nothing, and the version row is still written — indistinguishable from a
   soft ALTER that legitimately failed. The discipline's answer is the same as
   everywhere else (follow it with a hard statement naming the columns), so
   the runner does not check the key. Pinned by a test.
2. **A soft failure's reason is unrecoverable.** `pcall` discards the message
   and there is no hook to report it, so the only evidence that a soft
   statement failed for the wrong reason is the hard statement that follows
   raising. Adding an `on_error` hook would be a new behaviour, not an
   extraction.
3. **`schema_version()` raises if the table does not exist.** It is only ever
   called after a successful `migrate()` — supervisor's one caller,
   `/v1/admin/stats`, is reachable only through `resolve_account`, which
   answers 503 while the database is not ready — so the bootstrap has always
   run first. Left as a raise rather than given a 0 default, because a 0 there
   would read as "a fresh database" when it actually means "the handle is not
   the one you migrated".
4. **A version recorded by a newer build is invisible to an older one.** The
   done set is a membership test, not a high-water mark, so version 9 being
   present does not stop version 8 from being applied afterwards. That is
   deliberate for out-of-order merges, but it means a downgrade re-applies
   nothing and reports a `schema_version` that its own list cannot produce.

Two additions made on extraction, neither changing behaviour for a
well-formed list:

* `migrate()` returns the number of versions applied (the original returned
  nothing), so a caller can log what a boot did.
* `migrate()` asserts by name that `migrations` is an array and that each
  entry has a numeric `version` and a `statements` table, naming the index.
  Without it a malformed entry surfaces as a nil bind refusal from the
  connector several statements later.

## Consumption waits on `require`

DRT guests have no `require` and no `dofile` today; the load-time modules
slice is designed but unshipped. This is a real module — its last statement is
`return M` — and nothing imports it yet. That is expected, and it is not a
problem for this repo to solve.

Until then the tests concatenate: `test/run.sh` wraps `db.dlua` in an IIFE,
appends `test/cases.dlua`, and runs the result under `drt`. When `require`
lands, that becomes two `require` lines.

    sh test/run.sh          # DRT=/path/to/drt to point at another binary

A run is green only if the last line is exactly `PASS`.
