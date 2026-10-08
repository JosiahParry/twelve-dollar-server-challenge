library(yyjsonr)
library(plumber2)
library(adbcdrivermanager)

# load our auth handlers
source("auth.R")


# we use yyjsonr for serializing our json always
yyjsonr_serializing <- function(...) {
  function(x) {
    write_json_str(x, auto_unbox = TRUE)
  }
}

register_serializer("json", yyjsonr_serializing, "application/json")

# Open a new connection to a database
db <- adbc_database_init(
  adbcsqlite::adbcsqlite(),
  uri = Sys.getenv("SQLITE_PATH", unset = "seed/feed.db")
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


post_select <- "SELECT p.id, p.body, p.created_at, u.username as author, (SELECT count(*) FROM likes l WHERE l.post_id = p.id) as like_count FROM posts p JOIN users u ON u.id = p.user_id"
post_query <- sprintf("%s where p.id = ?", post_select)
feed_sql <- sprintf(
  "%s order by p.created_at desc, p.id desc limit 20",
  post_select
)
insert_like <- "INSERT INTO likes (user_id, post_id) SELECT ?1, ?2 WHERE EXISTS (SELECT 1 FROM posts WHERE id = ?2) ON CONFLICT (user_id, post_id) DO NOTHING RETURNING post_id"

get_post <- function(con, id, response) {
  resp <- read_adbc(con, post_query, bind = data.frame(id = id)) |>
    as.data.frame()

  if (nrow(resp) == 0L) {
    response$status <- 404L
    return(list(error = "post not found"))
  }

  # need to coerce to integer because R doesn't support i64 😭
  resp$id <- as.integer(resp$id)
  resp$like_count <- as.integer(resp$like_count)
  list(post = unclass(resp))
}

get_feed <- function(con) {
  resp <- read_adbc(con, feed_sql) |>
    as.data.frame()
  resp$id <- as.integer(resp$id)
  resp$like_count <- as.integer(resp$like_count)
  list(posts = resp)
}


create_post <- function(con, user_id, body, response) {
  message(sprintf("user_id: %s", user_id))
  message(sprintf("body: %s", body))
  resp <- read_adbc(
    con,
    "INSERT INTO posts (user_id, body) VALUES (?, ?) RETURNING id, created_at",
    bind = data.frame(user_id = user_id, body = body)
  ) |>
    as.data.frame()
  message(yyjsonr::write_json_str(resp))
  get_post(con, as.integer(resp$id), response)
}

like_post <- function(request, response, id) {
  id <- validate_post_id(id, response)
  if (is.list(id)) {
    return(id)
  }
  # authorize the user
  user <- authorize(request, response, secret = secret)
  if (is.null(user$sub)) {
    return(user)
  }

  # try inserting the like, return an error if we one.
  res <- rlang::try_fetch(
    read_adbc(con, insert_like, bind = data.frame(user$sub, id)),
    error = \(err) {
      response$status <- 404L
      list(error = "post not found")
    }
  )

  if (!is.null(res$error)) {
    return(res)
  }

  resp <- as.data.frame(res)

  # when we have no rows that could be a missing post OR the post doesn't exist
  if (nrow(resp) == 0) {
    does_it_exist <- as.data.frame(read_adbc(
      con,
      "SELECT 1 FROM posts WHERE id = ?",
      bind = data.frame(id = id)
    ))

    if (nrow(does_it_exist) == 0L) {
      response$status <- 404L
      return(list(error = "post not found"))
    }

    response$status <- 200L
    return(list(liked = TRUE, already_liked = TRUE, post_id = id))
  }

  response$status <- 201L
  list(liked = TRUE, already_liked = FALSE, post_id = id)
}


validate_post_id <- function(id, response) {
  id <- rlang::try_fetch(as.numeric(id), warning = \(cnd) {
    response$status <- 400L
    list(error = "invalid post id")
  })

  if (is.list(id)) {
    return(id)
  }

  if (!rlang::is_integerish(id) || id < 1L) {
    response$status <- 400L
    return(list(error = "invalid post id"))
  }
}

r <- api() |>
  api_logger(logger_console()) |>
  api_get(
    "/health",
    \() {
      health(con)
    }
  ) |>
  api_get("/feed", \() {
    get_feed(con)
  }) |>
  api_get("/posts/<id>", \(response, id) {
    id <- validate_post_id(id, response)
    if (is.list(id)) {
      return(id)
    }
    get_post(con, as.integer(id), response)
  }) |>
  api_post("/posts", \(request, response, body) {
    user <- authorize(request, response, secret = secret)
    if (is.null(user$sub)) {
      return(user)
    }

    res <- create_post(con, user$sub, body$body, response)
    response$status <- 201L
    res
  }) |>
  api_post("/posts/<id>/like", like_post) |>
  api_run(
    host = Sys.getenv("HOST", "127.0.0.1"),
    port = as.integer(Sys.getenv("PORT", "8080"))
  )

## Endpoints

# | Request | Success | Body |
# |---|---|---|
# | `GET /health` | 200 | `{"status":"ok","db":"ok","uptime_s":<int>}` after a `SELECT 1` succeeds. If it fails: 503 `{"status":"degraded","db":"unreachable","error":<string>}` |
# | `GET /feed` | 200 | `{"posts":[<post> × 20]}`: the 20 newest posts, `ORDER BY created_at DESC, id DESC` |
# | `GET /posts/:id` | 200 | `{"post":<post>}` |
# | `POST /posts` (auth) | 201 | `{"post":{"id":…,"body":<trimmed body>,"created_at":…,"author":<token username>,"like_count":0}}`. Request body: `{"body":"..."}` |
# | `POST /posts/:id/like` (auth) | 201 first time, 200 on repeats | `{"liked":true,"already_liked":<bool>,"post_id":<int>}`. One like per (user, post) |
