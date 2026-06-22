module Vision

import Util

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
# Per-profile gating: vision defaults ON. A profile (or the root settings)
# can opt OUT by setting vision:false — e.g. a text-only backend where a
# multimodal request would be rejected. supports() returns true unless the
# flag is explicitly falsy, so unflagged profiles are vision-enabled.

export [
    read_as_data_url, attach, get_pending, clear, supports,
    detect_mime, extract_image_paths, auto_attach,
    paste_from_clipboard
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
            r = shell_managed("base64 -i " ++ Util.shell_q(path) ++ " 2>/dev/null | tr -d '\\n'", 30000)
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

# ------------------------------------------------------------
# Path auto-detection — scan a line of user input for tokens that
# look like image file paths and exist on disk. Lets users drop a
# path into chat without having to ask the model to call
# read_image explicitly. Pattern mirrors claude-code's
# isImageFilePath check in utils/imagePaste.ts.
# ------------------------------------------------------------
# Naive token-split breaks on paths with unescaped spaces (common
# when users copy a Finder path or a WhatsApp filename). Instead we
# anchor on the image extension and walk LEFT, calling file_exists
# at each whitespace candidate. The first existing prefix wins.
# Capped at 8 word boundaries back so a runaway loop is bounded.
fun extract_image_paths(line) {
    extract_scan(line, 0, [])
}

fun extract_scan(line, i, acc) {
    if (i >= string_length(line)) { acc }
    else {
        ext_len = match_image_ext(line, i)
        if (ext_len > 0) {
            end_idx = i + ext_len
            path = grow_path_back(line, end_idx, i - 1, 0)
            new_acc = if (path == nil) { acc }
                      else { if (already_in(acc, path) == 'true') { acc }
                      else { list_append(acc, path) }}
            extract_scan(line, end_idx, new_acc)
        } else {
            extract_scan(line, i + 1, acc)
        }
    }
}

fun grow_path_back(line, end_idx, cursor, walks) {
    if (walks >= 8) { nil }
    else { if (cursor < 0) {
        path = string_sub(line, 0, end_idx)
        if (file_exists(path) == 'true') { path } else { nil }
    }
    else {
        c = string_sub(line, cursor, 1)
        if (c == " " || c == "\t" || c == "\n") {
            start = cursor + 1
            path = string_sub(line, start, end_idx - start)
            if (file_exists(path) == 'true') { path }
            else { grow_path_back(line, end_idx, cursor - 1, walks + 1) }
        } else {
            grow_path_back(line, end_idx, cursor - 1, walks)
        }
    }}
}

fun match_image_ext(line, i) {
    if (matches_ext_here(line, i, ".png")  == 'true') { 4 }
    else { if (matches_ext_here(line, i, ".jpg")  == 'true') { 4 }
    else { if (matches_ext_here(line, i, ".jpeg") == 'true') { 5 }
    else { if (matches_ext_here(line, i, ".gif")  == 'true') { 4 }
    else { if (matches_ext_here(line, i, ".webp") == 'true') { 5 }
    else { 0 }}}}}
}

fun matches_ext_here(line, i, needle) {
    n = string_length(needle)
    if (i + n > string_length(line)) { 'false' }
    else {
        slice = string_lower(string_sub(line, i, n))
        if (slice != needle) { 'false' }
        else {
            # Require a word boundary AFTER so we don't match the
            # `.png` inside a longer string like `.pngz`.
            if (i + n == string_length(line)) { 'true' }
            else {
                next_c = string_sub(line, i + n, 1)
                if (is_word_char(next_c) == 'true') { 'false' }
                else { 'true' }
            }
        }
    }
}

fun is_word_char(c) {
    if (c >= "a" && c <= "z") { 'true' }
    else { if (c >= "A" && c <= "Z") { 'true' }
    else { if (c >= "0" && c <= "9") { 'true' }
    else { if (c == "_") { 'true' }
    else { 'false' }}}}
}

fun already_in(lst, item) {
    if (length(lst) == 0) { 'false' }
    else {
        if (hd(lst) == item) { 'true' }
        else { already_in(tl(lst), item) }
    }
}

# auto_attach — extract image paths from `line`, attach each via the
# normal Vision.attach pipeline, return the list of attached paths so
# the caller can print a confirmation. No-op if profile doesn't
# support vision (avoids wasted base64 work).
fun auto_attach(opts, line) {
    if (supports(opts) == 'false') { [] }
    else {
        paths = extract_image_paths(line)
        auto_attach_loop(opts, paths, [])
    }
}

fun auto_attach_loop(opts, paths, acc) {
    if (length(paths) == 0) { acc }
    else {
        p = hd(paths)
        entry = attach(opts, p)
        new_acc = if (entry == nil) { acc } else { list_append(acc, p) }
        auto_attach_loop(opts, tl(paths), new_acc)
    }
}

# ------------------------------------------------------------
# Clipboard paste — extract a PNG from the system clipboard and
# stuff it through the normal attach pipeline. Cross-platform via
# osascript on darwin, xclip on linux. Returns the temp path on
# success, nil on failure (empty clipboard, no image, unsupported
# platform).
# ------------------------------------------------------------
fun paste_from_clipboard(opts) {
    ts = to_string(timestamp())
    tmp_path = "/tmp/swarm_paste_" ++ ts ++ ".png"
    cmd =
        "osascript -e 'set png to the clipboard as «class PNGf»' " ++
        "        -e 'set fh to open for access POSIX file " ++ Util.shell_q(tmp_path) ++
        "                  with write permission' " ++
        "        -e 'set eof of fh to 0' " ++
        "        -e 'write png to fh' " ++
        "        -e 'close access fh' 2>/dev/null || " ++
        "xclip -selection clipboard -t image/png -o > " ++ Util.shell_q(tmp_path) ++
        " 2>/dev/null"
    # 8s timeout — a wedged X server on a remote Linux session would otherwise
    # hang xclip (and the REPL). shell_managed enforces the timeout in C and
    # kills the whole process group; the old perl-alarm wrapper leaked the
    # xclip/osascript grandchild and could wedge swarmrt's shell() exit-poll.
    r = shell_managed(cmd, 8000)
    interrupted = elem(r, 2)
    if (interrupted == 'true') { file_delete(tmp_path) ; nil }
    else { if (file_exists(tmp_path) == 'false') { nil }
    else {
        # Empty file = clipboard didn't have an image
        sz_r = shell("wc -c < " ++ Util.shell_q(tmp_path) ++ " 2>/dev/null")
        sz = string_trim(elem(sz_r, 1))
        if (sz == "0" || sz == "") {
            file_delete(tmp_path)
            nil
        } else {
            entry = attach(opts, tmp_path)
            if (entry == nil) { nil } else { tmp_path }
        }
    }}
}
