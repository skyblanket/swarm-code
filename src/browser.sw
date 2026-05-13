module Browser

# ============================================================
# Browser — CDP-over-WebSocket browser control, no Node, no Python
# ============================================================
#
# Drives a real Chrome instance via the Chrome DevTools Protocol.
# Speaks WebSocket directly via swarmrt's wsc_* builtins; spawns the
# browser via the chrome_launch builtin. Zero foreign-runtime
# dependencies — works as long as the user has any Chromium-based
# browser installed (Chrome / Chromium / Brave / Edge).
#
# Replaces the earlier ~/.swarm-code/tools/cdp_*.{py,js,sh} layer
# the agent had bootstrapped at runtime: that needed Node + Playwright
# (~300 MB install) plus a Python wrapper. This module needs neither.
#
# Public API:
#   init(headless?)            -> session (ETS table)
#   navigate(session, url)     -> 'ok' | err
#   click(session, selector)   -> 'ok' | err
#   type_text(s, sel, text)    -> 'ok' | err
#   screenshot(session, path)  -> 'ok: <bytes>' | err
#   get_text(s, selector?)     -> string  (whole page if no selector)
#   get_html(session)          -> string
#   get_url(session)           -> string
#   evaluate(session, expr)    -> JSON value (string|number|nil|...)
#   close(session)             -> 'ok'
#
# Session map (stored as ETS table):
#   'port'       — chrome remote debugging port
#   'target_id'  — first /json target id (the about:blank tab)
#   'ws'         — wsc handle (int)
#   'next_id'    — CDP message id counter
#   'launched'   — 'true' if WE launched chrome (so close kills it)

export [
    init,
    navigate, click, type_text, screenshot,
    get_text, get_html, get_url, evaluate,
    close,
    cdp_call
]

# ------------------------------------------------------------
# init — launch (or reuse) chrome, find a tab, connect WS
# ------------------------------------------------------------
fun init(headless) {
    port_v = chrome_launch(9222, headless)
    if (port_v == nil) {
        nil
    } else {
        port = to_string(port_v)
        # GET /json — list of debuggable targets. We pick the first
        # 'page' type. Chrome always opens at least one (about:blank).
        targets_json = http_get("http://127.0.0.1:" ++ port ++ "/json")
        if (targets_json == nil) { nil }
        else {
            targets = json_decode(targets_json)
            page = pick_page_target(targets)
            if (page == nil) { nil }
            else {
                ws_url = to_string(map_get(page, 'webSocketDebuggerUrl'))
                target_id = to_string(map_get(page, 'id'))
                ws = wsc_connect(ws_url)
                if (ws == nil) { nil }
                else {
                    sess = ets_new()
                    ets_put(sess, 'port', port_v)
                    ets_put(sess, 'target_id', target_id)
                    ets_put(sess, 'ws', ws)
                    ets_put(sess, 'next_id', 0)
                    ets_put(sess, 'launched', 'true')
                    # Enable Page domain so navigation events fire.
                    cdp_call(sess, "Page.enable", %{})
                    cdp_call(sess, "Runtime.enable", %{})
                    sess
                }
            }
        }
    }
}

# Find first target whose type is "page". CDP also returns
# "background_page", "service_worker", "iframe" etc. — we ignore them.
fun pick_page_target(targets) {
    if (targets == nil) { nil }
    else { pick_page_loop(targets) }
}

fun pick_page_loop(targets) {
    if (length(targets) == 0) { nil }
    else {
        t = hd(targets)
        ttype = map_get(t, 'type')
        if (ttype == "page") { t } else { pick_page_loop(tl(targets)) }
    }
}

# ------------------------------------------------------------
# cdp_call — send a CDP method, block for matching response
# ------------------------------------------------------------
# CDP is request/response over a WS that ALSO carries async events.
# Each request gets an integer id; the response echoes that id.
# We loop wsc_recv, skipping any frame whose id doesn't match (or
# has no id at all — those are events). Bounded by timeout_ms.
fun cdp_call(session, method, params) {
    cdp_call_with_timeout(session, method, params, 30000)
}

fun cdp_call_with_timeout(session, method, params, timeout_ms) {
    new_id = next_msg_id(session)
    ws = ets_get(session, 'ws')
    payload = json_encode(%{
        id: new_id,
        method: method,
        params: params
    })
    rc = wsc_send(ws, payload)
    if (rc != 'ok') { nil }
    else { wait_for_response(ws, new_id, timeout_ms) }
}

fun next_msg_id(session) {
    cur = ets_get(session, 'next_id')
    cur_n = if (cur == nil) { 0 } else { cur }
    nx = cur_n + 1
    ets_put(session, 'next_id', nx)
    nx
}

# Pull frames off the WS until we see one whose id matches. Drops
# events on the floor — we don't have a pubsub layer for them yet.
fun wait_for_response(ws, target_id, timeout_ms) {
    raw = wsc_recv(ws, timeout_ms)
    if (raw == nil) { nil }
    else {
        decoded = json_decode(raw)
        msg_id = map_get(decoded, 'id')
        if (msg_id == target_id) {
            err = map_get(decoded, 'error')
            if (err != nil) {
                # CDP reported an error; surface its message.
                em = map_get(err, 'message')
                "error: " ++ to_string(em)
            } else {
                map_get(decoded, 'result')
            }
        } else {
            # Event frame or stale — keep listening.
            wait_for_response(ws, target_id, timeout_ms)
        }
    }
}

# ------------------------------------------------------------
# navigate — Page.navigate, then wait for load
# ------------------------------------------------------------
fun navigate(session, url) {
    result = cdp_call(session, "Page.navigate", %{url: to_string(url)})
    if (result == nil) { "error: navigate failed" }
    else { if (string_starts_with(to_string(result), "error:") == 'true') { result }
    else {
        # Best-effort wait for network idle. We sleep a bit; a proper
        # implementation would consume Page.loadEventFired events.
        sleep(800)
        "ok"
    }}
}

# ------------------------------------------------------------
# click / type_text — implemented via Runtime.evaluate to keep the
# protocol surface small. CDP has DOM.querySelector +
# Input.dispatchMouseEvent for "real" clicks but for v1 a JS click
# covers 95% of cases without coordinate math.
# ------------------------------------------------------------
fun click(session, selector) {
    sel = escape_js_string(selector)
    expr = "(() => { const el = document.querySelector(\"" ++ sel ++ "\"); if (!el) return 'NOT_FOUND'; el.click(); return 'OK'; })()"
    result = cdp_call(session, "Runtime.evaluate", %{
        expression: expr,
        returnByValue: 'true'
    })
    interpret_eval_result(result, "click")
}

fun type_text(session, selector, text) {
    sel = escape_js_string(selector)
    txt = escape_js_string(text)
    expr = "(() => { const el = document.querySelector(\"" ++ sel ++ "\"); if (!el) return 'NOT_FOUND'; el.focus(); el.value = \"" ++ txt ++ "\"; el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true})); return 'OK'; })()"
    result = cdp_call(session, "Runtime.evaluate", %{
        expression: expr,
        returnByValue: 'true'
    })
    interpret_eval_result(result, "type_text")
}

fun interpret_eval_result(result, label) {
    if (result == nil) { "error: " ++ label ++ " failed (nil)" }
    else { if (string_starts_with(to_string(result), "error:") == 'true') { result }
    else {
        ro = map_get(result, 'result')
        if (ro == nil) { "ok" }
        else {
            v = map_get(ro, 'value')
            if (v == "NOT_FOUND") { "error: selector not found" }
            else { "ok" }
        }
    }}
}

# ------------------------------------------------------------
# screenshot — Page.captureScreenshot returns base64 PNG. We pipe it
# through `base64 -d` via shell into the requested path. Keeps us out
# of the business of decoding 300 KB images in sw (and avoids needing
# a base64_decode builtin in swarmrt).
# ------------------------------------------------------------
fun screenshot(session, path) {
    p = to_string(path)
    result = cdp_call_with_timeout(session, "Page.captureScreenshot", %{format: "png"}, 60000)
    if (result == nil) { "error: screenshot failed" }
    else { if (string_starts_with(to_string(result), "error:") == 'true') { result }
    else {
        b64 = map_get(result, 'data')
        if (b64 == nil) { "error: no data in screenshot result" }
        else {
            tmp = "/tmp/swc-screenshot-" ++ to_string(timestamp()) ++ ".b64"
            file_write(tmp, to_string(b64))
            cmd = "base64 -d -i " ++ tmp ++ " > " ++ shell_quote_local(p) ++ " && rm -f " ++ tmp
            shell(cmd)
            "ok: wrote screenshot to " ++ p
        }
    }}
}

# Local shell quoter (Tools.shell_quote isn't importable here without
# pulling in the whole module). Uses single quotes; embedded ' becomes '\''.
fun shell_quote_local(s) {
    "'" ++ shell_quote_loop(s, 0, "") ++ "'"
}

fun shell_quote_loop(s, i, acc) {
    if (i >= string_length(s)) { acc }
    else {
        ch = string_sub(s, i, 1)
        next_acc = if (ch == "'") { acc ++ "'\\''" } else { acc ++ ch }
        shell_quote_loop(s, i + 1, next_acc)
    }
}

# ------------------------------------------------------------
# get_text / get_html / get_url / evaluate
# ------------------------------------------------------------
fun get_text(session, selector) {
    expr = if (selector == nil || string_length(to_string(selector)) == 0) {
        "document.body.innerText"
    } else {
        sel = escape_js_string(to_string(selector))
        "(() => { const el = document.querySelector(\"" ++ sel ++ "\"); return el ? el.innerText : 'NOT_FOUND'; })()"
    }
    eval_string(session, expr)
}

fun get_html(session) {
    eval_string(session, "document.documentElement.outerHTML")
}

fun get_url(session) {
    eval_string(session, "window.location.href")
}

fun evaluate(session, expr) {
    eval_string(session, to_string(expr))
}

# Run a JS expression, return its string value. Numbers/bools get
# stringified by Runtime.evaluate when returnByValue is set.
fun eval_string(session, expr) {
    result = cdp_call(session, "Runtime.evaluate", %{
        expression: expr,
        returnByValue: 'true'
    })
    if (result == nil) { "error: evaluate failed" }
    else { if (string_starts_with(to_string(result), "error:") == 'true') { result }
    else {
        ro = map_get(result, 'result')
        if (ro == nil) { "" }
        else {
            v = map_get(ro, 'value')
            if (v == nil) { "" } else { to_string(v) }
        }
    }}
}

# ------------------------------------------------------------
# close — close the WS, optionally kill chrome
# ------------------------------------------------------------
fun close(session) {
    ws = ets_get(session, 'ws')
    if (ws != nil) { wsc_close(ws) }
    # We DON'T kill chrome by default — the next session can attach
    # back to the same instance and skip the 1-2s launch wait. To
    # actually kill chrome, the caller can do a bash 'pkill -f
    # remote-debugging-port=9222' — exposing that as a tool would be
    # easy but isn't part of v1.
    "ok"
}

# ------------------------------------------------------------
# JS-string escaping — minimal: \, ", and newline. Selectors and user
# text are passed through this before being interpolated into JS.
# ------------------------------------------------------------
fun escape_js_string(s) {
    str = to_string(s)
    js_esc_loop(str, 0, "")
}

fun js_esc_loop(s, i, acc) {
    if (i >= string_length(s)) { acc }
    else {
        ch = string_sub(s, i, 1)
        esc = if (ch == "\\") { "\\\\" }
              else { if (ch == "\"") { "\\\"" }
              else { if (ch == "\n") { "\\n" }
              else { if (ch == "\r") { "\\r" }
              else { ch }}}}
        js_esc_loop(s, i + 1, acc ++ esc)
    }
}
