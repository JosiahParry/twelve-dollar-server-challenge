# R + plumber2

| | |
|---|---|
| Language | R 4.6.1 (Posit r-builds) |
| Framework | plumber2 0.2.0 (on fiery / httpuv) |
| SQLite driver | DBI 1.3.0 + RSQLite 3.53.3 (bundled SQLite) |
| JSON | yyjsonr 0.1.22 |
| JWT | jose 2.0.0 |
| **Nginx or direct** | **Behind Nginx**: listens on `127.0.0.1:3000` |

Packages are pinned by installing from the 2026-10-07 Posit Package Manager snapshot.

## Running it

```bash
sudo bash install.sh   # R 4.6.1 from Posit's r-builds
bash build.sh          # installs packages into ./lib
SQLITE_PATH=... JWT_SECRET=... HOST=127.0.0.1 PORT=3000 bash start.sh
```

## Optimizations, and why

- **RSQLite instead of ADBC.** I first wrote this with ADBC. Converting nanoarrow results to data
  frames, and coercing int64, cost more per request than the queries did. RSQLite with
  `bigint = "integer"` returns plain R integers. Locally it handled about 30% more req/s.
- **yyjsonr for JSON in and out.** A custom serializer and parser replace plumber2's defaults. The
  parser marks malformed bodies, so the handler can return the spec's `{"error":...}` shape after auth.
- **One connection, one process.** R is single-threaded and the box has one vCPU, so async (mirai)
  workers would only compete with the main process for the same core.
- **SQL**: the reference queries. Each like is a single statement,
  `INSERT ... SELECT ... WHERE EXISTS (post) ON CONFLICT DO NOTHING RETURNING post_id`. The existence
  check only runs when that inserts nothing.
- **Pragmas**: the same as the Python submission: WAL, `synchronous=NORMAL`, 1 GiB `mmap_size`, 64 MiB
  page cache, in-memory temp store.
- **Logging off.** The request logger is disabled.

## License

MIT, under the repo's [license](../../LICENSE).
