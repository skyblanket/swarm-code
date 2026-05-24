module Vision

# ============================================================
# Vision — image attachments for the next LLM request
# ============================================================
#
# Flow:
#   1. User mentions an image path in a message:
#        "/Users/sky/Downloads/photo.jpg  what's in this?"
#   2. Model decides to look and calls `read_image({path: "..."})`.
#   3. read_image base64-encodes the file, builds a data: URL, and
#      stuffs it into a session-scoped ETS attachments queue.
#   4. The handler returns "ok: image attached" so the model can
#      continue the turn and ask its question.
#   5. On the NEXT outbound LLM request, llm.sw checks the queue.
#      If non-empty, the latest user message's text is transformed
#      into a multimodal content array — the image blocks come
#      before the text — and the queue is cleared.
#
# Wire format (OpenAI multimodal):
#   {"role": "user", "content": [
#       {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,…"}},
#       {"type": "text",      "text": "what's in this?"}
#   ]}
#
# Per-profile gating: profiles in settings.json that support vision
# (kimi, z.ai GLM-5, multimodal Gemma 4 weights) must set vision:true.
# Profiles without the flag get a refusal from read_image so we don't
# burn tokens on an API rejection.

export [
    read_as_data_url, attach, get_pending, clear, supports,
    detect_mime
]

# ------------------------------------------------------------
# Read file at `path` and return a base64-encoded data URL, or
# nil on error. Shells out to `base64` because swarmrt has no
# in-process base64 builtin. One shell call per image is fine —
# vision turns are rare and base64 is fast.
# ------------------------------------------------------------
fun read_as_data_url(path) {
    if (file_exists(path) == 'false') { nil }
    else {
        mime = detect_mime(path)
        if (mime == nil) { nil }
        else {
            r = shell("base64 -i " ++ shell_q(path) ++ " 2>/dev/null | tr -d '\\n'")
            code = elem(r, 0)
            b64 = string_trim(elem(r, 1))
            if (code != 0 || string_length(b64) == 0) { nil }
            else { "data:" ++ mime ++ ";base64," ++ b64 }
        }
    }
}

fun detect_mime(path) {
    p = string_lower(path)
    if (string_ends_with(p, ".png") == 'true')  { "image/png" }
    else { if (string_ends_with(p, ".jpg") == 'true')  { "image/jpeg" }
    else { if (string_ends_with(p, ".jpeg") == 'true') { "image/jpeg" }
    else { if (string_ends_with(p, ".gif") == 'true')  { "image/gif" }
    else { if (string_ends_with(p, ".webp") == 'true') { "image/webp" }
    else { nil }}}}}
}

# ------------------------------------------------------------
# Session attachment queue (ETS-backed, opaque to callers).
# Entries: %{path, data_url}.  llm.sw drains via get_pending +
# clear on the next outbound request.
# ------------------------------------------------------------
fun attach(opts, path) {
    table = get_table(opts)
    if (table == nil) { nil }
    else {
        data_url = read_as_data_url(path)
        if (data_url == nil) { nil }
        else {
            existing = ets_get(table, 'pending')
            current = if (existing == nil) { [] } else { existing }
            entry = %{path: path, data_url: data_url}
            ets_put(table, 'pending', list_append(current, entry))
            entry
        }
    }
}

fun get_pending(opts) {
    table = get_table(opts)
    if (table == nil) { [] }
    else {
        p = ets_get(table, 'pending')
        if (p == nil) { [] } else { p }
    }
}

fun clear(opts) {
    table = get_table(opts)
    if (table != nil) { ets_put(table, 'pending', []) }
    'ok'
}

fun get_table(opts) { map_get(opts, 'attachments_table') }

# ------------------------------------------------------------
# Per-profile vision capability — read from settings.json under
# profiles.<active>.vision (boolean). Default false. Override
# with env var SWARM_CODE_VISION=1 for ad-hoc testing.
# ------------------------------------------------------------
fun supports(opts) {
    # Default ON. The model can always try read_image; if the endpoint
    # rejects multimodal content the user sees a clean server error and
    # can switch profiles. Hard-disable a profile with vision:"false"
    # in settings.json or SWARM_CODE_VISION=0.
    #
    # Resolution: env > opts.vision (live override) > profile.vision >
    # root settings.vision > default true. opts.vision is set by
    # llm.sw's apply_override when /profile NAME is invoked mid-session,
    # so vision tracks live profile swaps.
    env_force = getenv("SWARM_CODE_VISION")
    if (env_force == "1") { 'true' }
    else { if (env_force == "0") { 'false' }
    else {
        live = map_get(opts, 'vision')
        if (is_falsy_flag(live) == 'true') { 'false' }
        else { if (is_truthy_flag(live) == 'true') { 'true' }
        else {
            settings = map_get(opts, 'settings')
            if (settings == nil) { 'true' }  # no settings → default on
            else {
                profile_name = map_get(opts, 'profile')
                profile_v = if (profile_name == nil) { nil }
                            else {
                                profiles = map_get(settings, 'profiles')
                                if (profiles == nil) { nil }
                                else {
                                    p = profile_lookup(profiles, to_string(profile_name))
                                    if (p == nil) { nil } else { map_get(p, 'vision') }
                                }
                            }
                if (is_falsy_flag(profile_v) == 'true') { 'false' }
                else { if (is_truthy_flag(profile_v) == 'true') { 'true' }
                else {
                    root_v = map_get(settings, 'vision')
                    if (is_falsy_flag(root_v) == 'true') { 'false' }
                    else { 'true' }   # default ON
                }}
            }
        }}
    }}
}

fun is_truthy_flag(v) {
    if (v == nil) { 'false' }
    else { if (v == 'true' || v == "true" || v == 1) { 'true' }
    else { 'false' }}
}

fun is_falsy_flag(v) {
    if (v == nil) { 'false' }
    else { if (v == 'false' || v == "false" || v == 0) { 'true' }
    else { 'false' }}
}

# JSON-decoded maps have atom keys, so map_get(profiles, "kimi")
# misses. Walk and string-compare.
fun profile_lookup(profiles, name) {
    direct = map_get(profiles, name)
    if (direct != nil) { direct }
    else { profile_lookup_loop(map_keys(profiles), map_values(profiles), name) }
}

fun profile_lookup_loop(keys, values, name) {
    if (length(keys) == 0) { nil }
    else {
        if (to_string(hd(keys)) == name) { hd(values) }
        else { profile_lookup_loop(tl(keys), tl(values), name) }
    }
}

fun shell_q(s) { "'" ++ string_replace(s, "'", "'\\''") ++ "'" }
