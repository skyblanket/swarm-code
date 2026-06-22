module Browser

import UI

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
    console_logs,
    cdp_call
]

# ------------------------------------------------------------
# init — launch (or reuse) chrome, find a tab, connect WS
# ------------------------------------------------------------
fun init(headless) {
    # Prefer ATTACHING to a Chrome already listening on 9222 (one the user
    # started with --remote-debugging-port, or a prior session) so we drive a
    # real, visible browser. Otherwise launch one — do_browser_launch now passes
    # headless='false' by default, so WebGL renders for real and you can watch.
    existing = http_get("http://127.0.0.1:9222/json")
    port_v = if (existing != nil) { 9222 } else { chrome_launch(9222, headless) }
    if (port_v == nil) {
        nil
    } else {
        port = to_string(port_v)
        targets_json = if (existing != nil) { existing }
                       else { http_get("http://127.0.0.1:" ++ port ++ "/json") }
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
                    cdp_call(sess, "Log.enable", %{})
                    install_console_capture(sess)
                    sess
                }
            }
        }
    }
}

# Inject a shim that runs BEFORE page scripts on every navigation and records
# console.log/warn/error + uncaught errors + promise rejections into
# window.__swc_logs, so browser_console can read what actually broke (e.g. the
# exception that left a WebGL canvas black). Requires the Page domain (enabled).
fun install_console_capture(session) {
    shim = "(function(){if(window.__swc_logs)return;window.__swc_logs=[];" ++
        "function rec(t,a){try{window.__swc_logs.push(t+': '+Array.prototype.slice.call(a).map(function(x){return (typeof x==='object')?JSON.stringify(x):String(x);}).join(' '));}catch(e){window.__swc_logs.push(t+': [unserializable]');}if(window.__swc_logs.length>300)window.__swc_logs.shift();}" ++
        "['log','warn','error','info'].forEach(function(m){var o=console[m]?console[m].bind(console):function(){};console[m]=function(){rec(m,arguments);o.apply(console,arguments);};});" ++
        "window.addEventListener('error',function(e){rec('uncaught',[(e.message||e.type)+' @ '+(e.filename||'')+':'+(e.lineno||'')]);});" ++
        "window.addEventListener('unhandledrejection',function(e){rec('promise',[String(e.reason)]);});})();"
    cdp_call(session, "Page.addScriptToEvaluateOnNewDocument", %{source: shim})
}

# Read what the in-page shim captured (console output + JS errors), as a JSON
# array string. Empty until the page is (re)navigated with the shim installed.
fun console_logs(session) {
    raw = eval_string(session, "JSON.stringify(window.__swc_logs || [])", nil, nil)
    if (raw == nil) { "[]" } else { raw }
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
    # Internal/fast calls (domain enables, console reads): no heartbeat —
    # a nil label disables the "still running" line in the poll loop.
    cdp_call_pg(session, method, params, 30000, nil, nil)
}

fun cdp_call_with_timeout(session, method, params, timeout_ms) {
    cdp_call_pg(session, method, params, timeout_ms, nil, nil)
}

# ------------------------------------------------------------
# Tool-wait heartbeat (browser_*) — mirrors agent.sw's collect_tool_result
# affordance. browser_* tools bypass exec_tool_isolated/collect_tool_result
# (they must run in-process to keep the CDP/WS session), so the 4s "still
# running" line is wired directly into the bounded poll loops here, reusing
# UI.tool_progress / UI.tool_progress_clear. A nil `label` is the no-op path
# (internal fast calls); a real label + interactive opts draws the line.
# ------------------------------------------------------------
fun BROWSER_PROGRESS_THRESHOLD_MS() { 4000 }

# No-op in headless/one-shot and subagent runs — same gate llm.sw/agent.sw use.
fun browser_progress_enabled(opts) {
    if (opts == nil) { 'false' }
    else { if (map_get(opts, 'headless') == 'true') { 'false' }
    else { if (map_get(opts, 'is_subagent') == 'true') { 'false' }
    # mcp_server mode reserves stdout for JSON-RPC — never print there.
    else { if (map_get(opts, 'execution_context') == "mcp_server") { 'false' } else { 'true' } }}}
}

# Whether THIS call should surface a heartbeat at all (label set + interactive).
fun browser_pg_on(label, opts) {
    if (label == nil) { 'false' } else { browser_progress_enabled(opts) }
}

fun cdp_call_pg(session, method, params, timeout_ms, label, opts) {
    new_id = next_msg_id(session)
    ws = ets_get(session, 'ws')
    payload = json_encode(%{
        id: new_id,
        method: method,
        params: params
    })
    rc = wsc_send(ws, payload)
    if (rc != 'ok') {
        # transport send failed — the WS is gone. Flag the session so the next
        # browser call transparently relaunches instead of reusing a dead handle.
        ets_put(session, 'dead', 'true')
        nil
    }
    else {
        resp = wait_for_response(ws, new_id, timeout_ms, label, opts, timestamp())
        if (resp == nil) {
            # timed out or socket died — don't keep operating on a wedged
            # session; mark it for relaunch on the next call.
            ets_put(session, 'dead', 'true')
            nil
        } else { resp }
    }
}

fun next_msg_id(session) {
    random_int(1, 2147483647)
}

# Pull frames off the WS until we see one whose id matches. Drops
# events on the floor — we don't have a pubsub layer for them yet.
# Bounded by an ABSOLUTE deadline (like wait_for_event): a live page
# emitting a steady stream of event frames must not be able to reset the
# timeout on every frame and wedge us forever. We listen in <=2s slices.
fun wait_for_response(ws, target_id, timeout_ms, label, opts, started) {
    wait_for_response_loop(ws, target_id, timestamp() + timeout_ms, label, opts, started, 'false')
}

# `started`/`label`/`opts` carry the tool-wait heartbeat context (see
# cdp_call_pg); `shown` tracks whether a "still running" line is up so we
# clear it on exit. `pg_tick` surfaces/refreshes the line and is a no-op
# when label==nil or the run is headless/subagent.
fun wait_for_response_loop(ws, target_id, deadline, label, opts, started, shown) {
    now = timestamp()
    if (now >= deadline) { pg_clear(shown) }
    else {
        remaining = deadline - now
        slice = if (remaining > 2000) { 2000 } else { remaining }
        raw = wsc_recv(ws, slice)
        if (raw == nil) {
            # wsc_recv returns nil on BOTH a per-slice timeout AND a closed or
            # broken connection. A genuine timeout consumes ~the whole slice; a
            # dead fd returns nil almost instantly (and with no yield). If it
            # came back well before the slice elapsed, the socket is gone — fail
            # fast instead of busy-recursing to the deadline.
            elapsed = timestamp() - now
            if (elapsed + 100 < slice) { pg_clear(shown) }
            else {
                next_shown = pg_tick(label, opts, started, shown)
                wait_for_response_loop(ws, target_id, deadline, label, opts, started, next_shown)
            }
        } else {
            decoded = json_decode(raw)
            msg_id = map_get(decoded, 'id')
            if (msg_id == target_id) {
                if (shown == 'true') { UI.tool_progress_clear() }
                err = map_get(decoded, 'error')
                if (err != nil) {
                    # CDP reported an error; surface its message.
                    em = map_get(err, 'message')
                    "error: " ++ to_string(em)
                } else {
                    map_get(decoded, 'result')
                }
            } else {
                # Event frame or stale — keep listening under the SAME deadline.
                next_shown = pg_tick(label, opts, started, shown)
                wait_for_response_loop(ws, target_id, deadline, label, opts, started, next_shown)
            }
        }
    }
}

# Heartbeat helpers shared by both poll loops. pg_tick draws/refreshes the
# dim "still running (Ns)" line once past the threshold, returns the new
# `shown` flag. pg_clear clears any drawn line and returns nil (the loops'
# nil-result exits flow through it). Both no-op when the call opted out.
fun pg_tick(label, opts, started, shown) {
    if (browser_pg_on(label, opts) == 'false') { shown }
    else {
        elapsed = timestamp() - started
        if (elapsed >= BROWSER_PROGRESS_THRESHOLD_MS()) {
            UI.tool_progress(label, elapsed / 1000)
            'true'
        } else { shown }
    }
}

fun pg_clear(shown) {
    if (shown == 'true') { UI.tool_progress_clear() }
    nil
}

# ------------------------------------------------------------
# navigate — Page.navigate, then wait for load
# ------------------------------------------------------------
fun navigate(session, url, opts) {
    result = cdp_call_pg(session, "Page.navigate", %{url: to_string(url)}, 30000, "browser_navigate", opts)
    if (result == nil) { "error: navigate failed" }
    else { if (string_starts_with(to_string(result), "error:") == 'true') { result }
    else {
        # Wait for the real Page.loadEventFired event rather than a blind
        # sleep — fast pages proceed immediately, slow ones aren't raced.
        # The Page domain was enabled in init() so the event fires.
        # Page.navigate's own response lands before load, so the event
        # is still in flight here, not already dropped by cdp_call.
        ws = ets_get(session, 'ws')
        waited = wait_for_event(ws, "Page.loadEventFired", nav_load_timeout_ms(), "browser_navigate", opts, timestamp())
        # Brief settle for post-load script / first paint regardless.
        sleep(150)
        if (waited == 'ok') {
            "ok"
        } else {
            "ok (proceeded after " ++ to_string(nav_load_timeout_ms() / 1000) ++
            "s — load event not seen; page may still be loading)"
        }
    }}
}

# How long navigate waits for Page.loadEventFired before giving up.
# A page that never fires load (long-poll apps, a hung sub-resource)
# must not be able to wedge the agent.
fun nav_load_timeout_ms() { 10000 }

# Drain CDP frames off the WS until one carries method == `method`, or
# the deadline passes. CDP events have no `id`, so cdp_call's response
# waiter drops them — navigation waits on the event channel directly.
fun wait_for_event(ws, method, timeout_ms, label, opts, started) {
    wait_for_event_loop(ws, method, timestamp() + timeout_ms, label, opts, started, 'false')
}

fun wait_for_event_loop(ws, method, deadline, label, opts, started, shown) {
    now = timestamp()
    if (now >= deadline) {
        if (shown == 'true') { UI.tool_progress_clear() }
        'timeout'
    }
    else {
        remaining = deadline - now
        slice = if (remaining > 2000) { 2000 } else { remaining }
        raw = wsc_recv(ws, slice)
        if (raw == nil) {
            # Same dead-vs-timeout discrimination as wait_for_response_loop: a
            # closed/broken socket returns nil instantly with no yield, so bail
            # rather than busy-spin to the deadline; a real timeout waited ~slice.
            elapsed = timestamp() - now
            if (elapsed + 100 < slice) {
                if (shown == 'true') { UI.tool_progress_clear() }
                'timeout'
            }
            else {
                next_shown = pg_tick(label, opts, started, shown)
                wait_for_event_loop(ws, method, deadline, label, opts, started, next_shown)
            }
        } else {
            decoded = json_decode(raw)
            m = if (decoded == nil) { nil } else { map_get(decoded, 'method') }
            if (m == method) {
                if (shown == 'true') { UI.tool_progress_clear() }
                'ok'
            }
            else {
                next_shown = pg_tick(label, opts, started, shown)
                wait_for_event_loop(ws, method, deadline, label, opts, started, next_shown)
            }
        }
    }
}

# ------------------------------------------------------------
# click / type_text — implemented via Runtime.evaluate to keep the
# protocol surface small. CDP has DOM.querySelector +
# Input.dispatchMouseEvent for "real" clicks but for v1 a JS click
# covers 95% of cases without coordinate math.
# ------------------------------------------------------------
fun click(session, selector, opts) {
    sel = escape_js_string(selector)
    expr = "(() => { const el = document.querySelector(\"" ++ sel ++ "\"); if (!el) return 'NOT_FOUND'; el.click(); return 'OK'; })()"
    result = cdp_call_pg(session, "Runtime.evaluate", %{
        expression: expr,
        returnByValue: 'true'
    }, 30000, "browser_click", opts)
    interpret_eval_result(result, "click")
}

fun type_text(session, selector, text, opts) {
    sel = escape_js_string(selector)
    txt = escape_js_string(text)
    expr = "(() => { const el = document.querySelector(\"" ++ sel ++ "\"); if (!el) return 'NOT_FOUND'; el.focus(); el.value = \"" ++ txt ++ "\"; el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true})); return 'OK'; })()"
    result = cdp_call_pg(session, "Runtime.evaluate", %{
        expression: expr,
        returnByValue: 'true'
    }, 30000, "browser_type", opts)
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
# screenshot — Page.captureScreenshot returns base64 PNG. We decode
# in-process via the base64_decode builtin (added 2026-05-15) and
# write binary directly. No tmp file, no shell pipe, no `rm -f`.
# ------------------------------------------------------------
fun screenshot(session, path, opts) {
    p = to_string(path)
    result = cdp_call_pg(session, "Page.captureScreenshot", %{format: "png"}, 30000, "browser_screenshot", opts)
    if (result == nil) { "error: screenshot failed (capture timed out or browser unresponsive)" }
    else { if (string_starts_with(to_string(result), "error:") == 'true') { result }
    else {
        b64 = map_get(result, 'data')
        if (b64 == nil) { "error: no data in screenshot result" }
        else {
            png = base64_decode(to_string(b64))
            if (png == nil) { "error: base64_decode failed" }
            else {
                # Validate the capture before writing. A blank/stalled page can
                # decode to a few junk bytes; writing that hands read_image
                # garbage and invites a hallucinated "I can see the page is X".
                # A real PNG screenshot is many KB — reject anything tiny.
                n = string_length(png)
                if (n < 100) {
                    "error: screenshot was empty/corrupt (" ++ to_string(n) ++
                    " bytes) — the page likely had not rendered; navigate again or wait, then re-screenshot"
                } else {
                    file_write(p, png)
                    "ok: wrote screenshot to " ++ p
                }
            }
        }
    }}
}

# shell quoting: use Util.shell_q (import Util at top of file if needed)

# ------------------------------------------------------------
# get_text / get_html / get_url / evaluate
# ------------------------------------------------------------
fun get_text(session, selector, opts) {
    expr = if (selector == nil || string_length(to_string(selector)) == 0) {
        "document.body.innerText"
    } else {
        sel = escape_js_string(to_string(selector))
        "(() => { const el = document.querySelector(\"" ++ sel ++ "\"); return el ? el.innerText : 'NOT_FOUND'; })()"
    }
    eval_string(session, expr, "browser_get_text", opts)
}

fun get_html(session, opts) {
    eval_string(session, "document.documentElement.outerHTML", "browser_get_html", opts)
}

fun get_url(session) {
    # Internal/fast read — no heartbeat (nil label).
    eval_string(session, "window.location.href", nil, nil)
}

fun evaluate(session, expr, opts) {
    eval_string(session, to_string(expr), "browser_evaluate", opts)
}

# Run a JS expression, return its string value. Numbers/bools get
# stringified by Runtime.evaluate when returnByValue is set. `label`/`opts`
# carry the tool-wait heartbeat context (nil label = no heartbeat).
fun eval_string(session, expr, label, opts) {
    result = cdp_call_pg(session, "Runtime.evaluate", %{
        expression: expr,
        returnByValue: 'true'
    }, 30000, label, opts)
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
