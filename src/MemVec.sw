# MemVec.sw — SQLite-backed vector store for semantic memory.
#
# Persistence layer for swarm-code's memory embedding cache.
# Stores one row per memory slug: the slug (PK), the embedding as a
# JSON float array, and the timestamp when it was embedded.
#
# Schema (at db_path, default ~/.swarm-code/memory/embed.db):
#
#   CREATE TABLE IF NOT EXISTS mem_vectors (
#     slug         TEXT PRIMARY KEY,
#     vec_json     TEXT NOT NULL,
#     embedded_at  INTEGER NOT NULL
#   )
#
# Public API:
#
#   db  = MemVec.open(path)                  — open/create DB
#   MemVec.close(db)                         — release handle
#   MemVec.upsert(db, slug, vec_list)        — store/update a vector
#   vec = MemVec.get_vector(db, slug)        — fetch one vector or nil
#   missing = MemVec.list_slugs_without_vector(db, all_slugs)
#   score   = MemVec.cosine_sim(a, b)        — pure-sw cosine similarity
#   hits    = MemVec.search_top_k(db, q, k)  — top-k %{slug, score}
#   vec     = MemVec.embed_text(text, opts)  — embed via Embed.create

module MemVec

import Embed

export [open, close, upsert, get_vector, list_slugs_without_vector,
        cosine_sim, search_top_k, embed_text]

# ============================================================
# 1. open — open or create the SQLite DB and ensure the schema exists.
# ============================================================
fun open(db_path) {
    db = db_open(db_path)
    db_exec(db,
        "CREATE TABLE IF NOT EXISTS mem_vectors (" ++
        "slug TEXT PRIMARY KEY, " ++
        "vec_json TEXT NOT NULL, " ++
        "embedded_at INTEGER NOT NULL)")
    db
}

# ============================================================
# 2. close — release the database handle.
# ============================================================
fun close(db) {
    db_close(db)
    'ok'
}

# ============================================================
# 3. upsert — INSERT OR REPLACE a (slug, vec_list) pair.
#    vec_list is a sw list of floats. Stored as a JSON string.
# ============================================================
fun upsert(db, slug, vec_list) {
    vec_json = json_encode(vec_list)
    db_query(db,
        "INSERT OR REPLACE INTO mem_vectors(slug, vec_json, embedded_at) VALUES (?, ?, ?)",
        [to_string(slug), vec_json, timestamp()])
    'ok'
}

# ============================================================
# 4. get_vector — SELECT vec_json for a single slug; decode to float list.
#    Returns nil if the slug is not in the table.
# ============================================================
fun get_vector(db, slug) {
    rows = db_query(db,
        "SELECT vec_json FROM mem_vectors WHERE slug = ?",
        [to_string(slug)])
    if (rows == nil) { nil }
    else {
        if (length(rows) == 0) { nil }
        else {
            row = hd(rows)
            vec_json = map_get(row, "vec_json")
            if (vec_json == nil) { nil }
            else { json_decode(to_string(vec_json)) }
        }
    }
}

# ============================================================
# 5. list_slugs_without_vector — given a list of known slugs,
#    return those that do NOT have a row in mem_vectors yet.
#    Used by the lazy-embed loop in memory.sw recall() to find
#    any un-embedded memories before a semantic search.
# ============================================================
fun list_slugs_without_vector(db, all_slugs) {
    filter_missing(db, all_slugs, [])
}

fun filter_missing(db, slugs, acc) {
    if (length(slugs) == 0) { acc }
    else {
        slug = hd(slugs)
        rows = db_query(db,
            "SELECT 1 FROM mem_vectors WHERE slug = ?",
            [to_string(slug)])
        new_acc = if (rows == nil || length(rows) == 0) {
            list_append(acc, slug)
        } else {
            acc
        }
        filter_missing(db, tl(slugs), new_acc)
    }
}

# ============================================================
# 6. cosine_sim — pure-sw cosine similarity.
#    Returns 0.0 if either vector is nil or empty.
#    Tail-recursive dot product and magnitude via Newton sqrt.
# ============================================================
fun cosine_sim(a, b) {
    if (a == nil || b == nil) { 0 }
    else {
        if (length(a) == 0 || length(b) == 0) { 0 }
        else {
            dp = vec_dot(a, b)
            mag_a = vec_sqrt(vec_dot(a, a))
            mag_b = vec_sqrt(vec_dot(b, b))
            if (mag_a == 0 || mag_b == 0) { 0 }
            else { dp / (mag_a * mag_b) }
        }
    }
}

# Tail-recursive dot product accumulator.
fun vec_dot(a, b) { vec_dot_acc(a, b, 0) }
fun vec_dot_acc(a, b, acc) {
    if (length(a) == 0 || length(b) == 0) { acc }
    else { vec_dot_acc(tl(a), tl(b), acc + hd(a) * hd(b)) }
}

# Newton's-method square root — 8 iterations sufficient for embedding
# vector magnitudes (same approach as Vec.sw).
fun vec_sqrt(x) {
    if (x <= 0) { 0 }
    else { vec_sqrt_iter(x, x / 2, 8) }
}
fun vec_sqrt_iter(x, guess, n) {
    if (n <= 0) { guess }
    else { vec_sqrt_iter(x, (guess + x / guess) / 2, n - 1) }
}

# ============================================================
# 7. search_top_k — load ALL vectors from DB, score each against
#    query_vec, return top-k sorted by cosine similarity descending.
#
#    Returns a list of %{slug, score} maps, highest score first.
#    At < 200 memories the O(N) scan is fine; no ANN needed.
# ============================================================
fun search_top_k(db, query_vec, k) {
    rows = db_query(db, "SELECT slug, vec_json FROM mem_vectors", [])
    if (rows == nil) { [] }
    else {
        scored = score_rows(query_vec, rows, [])
        top_k_sort(scored, k)
    }
}

# Score each row against the query vector.
fun score_rows(query_vec, rows, acc) {
    if (length(rows) == 0) { acc }
    else {
        row = hd(rows)
        slug = to_string(map_get(row, "slug"))
        vec_json_val = map_get(row, "vec_json")
        vec = if (vec_json_val == nil) { nil }
              else { json_decode(to_string(vec_json_val)) }
        new_acc = if (vec == nil) { acc }
                  else {
                      score = cosine_sim(query_vec, vec)
                      list_append(acc, %{slug: slug, score: score})
                  }
        score_rows(query_vec, tl(rows), new_acc)
    }
}

# Insertion-sort the top-K results by score descending.
# Fine for k up to ~50 and N up to ~200 — both true for this use-case.
fun top_k_sort(scored, k) { top_k_loop(scored, k, []) }

fun top_k_loop(scored, k, sorted) {
    if (length(scored) == 0) { take_n(sorted, k) }
    else { top_k_loop(tl(scored), k, insert_by_score(hd(scored), sorted, [])) }
}

# Insert item into sorted list (descending by score) preserving order.
fun insert_by_score(item, sorted, acc) {
    if (length(sorted) == 0) { list_append(acc, item) }
    else {
        h = hd(sorted)
        if (map_get(item, 'score') > map_get(h, 'score')) {
            acc ++ [item] ++ sorted
        } else {
            insert_by_score(item, tl(sorted), list_append(acc, h))
        }
    }
}

fun take_n(lst, n) {
    if (n <= 0 || length(lst) == 0) { [] }
    else { [hd(lst)] ++ take_n(tl(lst), n - 1) }
}

# ============================================================
# 8. embed_text — call Embed.create with opts derived from the
#    swarm-code settings convention.
#
#    opts keys read:
#      'embed_endpoint'  — e.g. "https://api.openai.com"
#      'embed_api_key'   — API key string
#      'embed_model'     — e.g. "text-embedding-3-small"
#
#    Returns a list of floats, or nil on any failure (network,
#    missing config, API error). Callers must nil-check before
#    storing or comparing.
# ============================================================
fun embed_text(text, opts) {
    endpoint = map_get(opts, 'embed_endpoint')
    api_key = map_get(opts, 'embed_api_key')
    model = map_get(opts, 'embed_model')
    # Require at minimum a key and model to attempt embedding.
    # Without them we'd send a malformed request and silently fail.
    if (api_key == nil || model == nil) { nil }
    else {
        embed_opts = %{
            endpoint: if (endpoint == nil) { "https://api.openai.com" } else { endpoint },
            key: api_key,
            model: model
        }
        Embed.create(embed_opts, to_string(text))
    }
}
