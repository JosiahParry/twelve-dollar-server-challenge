library(yyjsonr)
library(adbcdrivermanager)

# Open a new connection to a database
db <- adbc_database_init(
  adbcsqlite::adbcsqlite(),
  uri = "seed/feed.db"
)

con <- adbc_connection_init(db)

start <- Sys.time()

health <- function(con) {
  res <- rlang::try_fetch(read_adbc(con, "select 1"), error = function(cnd) {
    list(
      status = "degraded",
      "db" = "unreachable",
      error = as.character(cnd)
    )
  })

  if (rlang::inherits_only(res, "nanoarrow_array_stream")) {
    list(
      "status" = "ok",
      "db" = "ok",
      uptime_s = as.integer(difftime(Sys.time(), start))
    )
  } else {
    res
  }
}


user <- authorize(request, response, secret)


post_select <- "SELECT p.id, p.body, p.created_at, u.username, (SELECT count(*) FROM likes l WHERE l.post_id = p.id) as like_count FROM posts p JOIN users u ON u.id = p.user_id"
post_query <- sprintf("%s where p.id = ?", post_select)
feed_sql <- sprintf(
  "%s order by p.created_at desc, p.id desc limit 20",
  post_select
)


get_post <- function(con, id) {
  resp <- read_adbc(con, post_query, bind = data.frame(id = id)) |>
    as.data.frame() |>
    unclass()
  # need to coerce to integer because R doesn't support i64 😭
  resp$id <- as.integer(resp$id)
  resp$like_count <- as.integer(resp$like_count)
  list(post = resp)
}

get_feed <- function(con) {
  resp <- read_adbc(con, feed_sql) |>
    as.data.frame()
  resp$id <- as.integer(resp$id)
  resp$like_count <- as.integer(resp$like_count)
  list(posts = resp)
}


create_post <- function(con, user_id, body) {
  resp <- read_adbc(
    con,
    "INSERT INTO posts (user_id, body) VALUES (?, ?) RETURNING id, created_at",
    bind = data.frame(user_id = user_id, body = body)
  ) |>
    as.data.frame()
  get_post(con, resp$id)
}

library(plumber2)

yyjsonr_serializing <- function(...) {
  function(x) {
    write_json_str(x, auto_unbox = TRUE)
  }
}

register_serializer("json", yyjsonr_serializing, "application/json")

api() |>
  api_get(
    "/health",
    \() {
      health(con)
    }
  ) |>
  api_get("/feed", \() {
    get_feed(con)
  }) |>
  api_get("/posts/<id:integer>", \(id) {
    get_post(con, id)
  }) |>
  api_run(block = TRUE)
# FEED_SQL = POST_SELECT + " ORDER BY p.created_at DESC, p.id DESC LIMIT 20"

## Endpoints

# | Request | Success | Body |
# |---|---|---|
# | `GET /health` | 200 | `{"status":"ok","db":"ok","uptime_s":<int>}` after a `SELECT 1` succeeds. If it fails: 503 `{"status":"degraded","db":"unreachable","error":<string>}` |
# | `GET /feed` | 200 | `{"posts":[<post> × 20]}`: the 20 newest posts, `ORDER BY created_at DESC, id DESC` |
# | `GET /posts/:id` | 200 | `{"post":<post>}` |
# | `POST /posts` (auth) | 201 | `{"post":{"id":…,"body":<trimmed body>,"created_at":…,"author":<token username>,"like_count":0}}`. Request body: `{"body":"..."}` |
# | `POST /posts/:id/like` (auth) | 201 first time, 200 on repeats | `{"liked":true,"already_liked":<bool>,"post_id":<int>}`. One like per (user, post) |
