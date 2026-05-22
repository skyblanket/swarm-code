# swarm-code

A terminal coding agent. Multi-agent, BYOM (bring your own model), written in
`sw` on the [swarmrt](https://github.com/skyblanket/swarmrt) BEAM-shaped C
runtime. Single ~3 MB native binary — no Node, no Python, no Electron.

- **One binary.** Download, run. No runtime to install, nothing to `npm i`.
- **Bring your own model.** Any OpenAI-compatible endpoint — a local
  llama.cpp / vLLM box, or a hosted provider. Kimi K2.6 by default.
- **Local by default.** It refuses to talk to a non-local endpoint unless
  you opt in. No telemetry, no analytics, no auto-updater, no phone-home.
- **Multi-agent.** Spawns subagents on the swarmrt scheduler for parallel
  work, with a real process model underneath (mailboxes, links, monitors).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/skyblanket/swarm-code/main/scripts/install.sh | sh
```

That drops `swarm` into `~/.local/bin` and writes a config stub at
`~/.swarm-code/settings.json`. Open it, paste your API key, then:

```bash
swarm
```

The installer detects your OS/arch and pulls the matching binary from the
[latest release](https://github.com/skyblanket/swarm-code/releases). Pin a
version with `--tag`, or change the install dir with `--bindir`.

## Usage

```
swarm                  start the interactive agent
swarm --help, -h       show usage and exit
swarm --version, -V    print the version and exit
swarm --print-config   show the resolved endpoint / model / config and exit
```

Inside the agent, type `/help` for the full slash-command list — `/model`,
`/tools`, `/status`, `/compact`, `/resume`, `/agents`, and more. `/quit`
exits.

## Configuration

swarm-code is BYOM. Settings are resolved in priority order:
**environment variables → `~/.swarm-code/settings.json` → built-in defaults.**

`~/.swarm-code/settings.json`:

```json
{
  "endpoint": "https://api.moonshot.ai/v1/chat/completions",
  "model":    "kimi-k2.6",
  "api_key":  "sk-...",
  "permissions": {
    "bash":  "allow",
    "read":  "allow",
    "write": "allow",
    "edit":  "allow",
    "web":   "allow"
  }
}
```

Per-project overrides live in `.swarm-code.json` at the project root and
merge over the user-global file. A `SWARM.md` (or `CLAUDE.md`) in the
working directory is loaded as project context.

Common environment variables (full behaviour documented at the top of
`src/main.sw`):

| Variable | Purpose |
|----------|---------|
| `SWARM_CODE_ENDPOINT` | LLM endpoint — base URL or full `/chat/completions` URL |
| `SWARM_CODE_MODEL` | Model name (default `kimi-k2.6`) |
| `SWARM_CODE_API_KEY` | API key for a remote provider |
| `SWARM_CODE_ALLOW_REMOTE` | Set to `1` to permit a non-local endpoint |
| `SWARM_CODE_MAX_OUTPUT_TOKENS` | Max tokens generated per turn |
| `SWARM_CODE_CWD` | Working directory shown to the model |
| `SW_QUIET` | Set to `1` to silence the swarmrt startup banner |

Run `swarm --print-config` to see exactly what these resolve to.

## Local by default

swarm-code makes network calls in only two places: the LLM endpoint, and
the `web_fetch` tool when the model explicitly uses it. On startup it
verifies the configured endpoint is on a local / private / Tailscale
network and **refuses to run against a public-internet endpoint** unless
you either set `SWARM_CODE_API_KEY` (an intentional opt-in to a hosted
provider) or `SWARM_CODE_ALLOW_REMOTE=1`. There is no telemetry, no
analytics, and no auto-updater anywhere in the binary.

## Platforms

macOS, Linux, and WSL2 are first-class. **Native Windows is not
supported** — there's no `swarm.exe` and no plan for one; Windows users
run swarm-code inside WSL2.

| Platform | Binary | Notes |
|----------|--------|-------|
| macOS Apple Silicon | `swarm-darwin-arm64` | |
| Linux x86_64 | `swarm-linux-x86_64` | covers WSL2 too |
| Linux ARM64 | `swarm-linux-arm64` | |
| macOS Intel | — | build from source (below) |
| Windows | — | install WSL2, then run the installer |

### Windows — set up WSL2 first

In an admin PowerShell:

```powershell
wsl --install      # one-time, ~2 min, may reboot
```

Then open Ubuntu from the Start menu and run the standard installer inside
that session:

```bash
curl -fsSL https://raw.githubusercontent.com/skyblanket/swarm-code/main/scripts/install.sh | sh
swarm
```

Your Windows drives are reachable from WSL at `/mnt/c`, `/mnt/d`, etc., so
swarm can edit files anywhere on the machine.

## Build from source

Needed for Intel Mac, or to hack on swarm-code itself. You'll need a C
compiler plus `libsqlite3-dev`, `libssl-dev`, `zlib1g-dev` on Linux — or
`brew install sqlite3` on macOS.

```bash
git clone https://github.com/skyblanket/swarmrt   ../swarmrt
git clone https://github.com/skyblanket/swarm-code
cd ../swarmrt   && make swc libswarmrt
cd ../swarm-code && make
./bin/swarm-code
```

The build expects `swarmrt` as a sibling directory; point elsewhere with
`make SWARMRT=/path/to/swarmrt`. When swarmrt changes, run `make clean &&
make` so swarm-code relinks against the new `libswarmrt.a`.

## License

MIT — see [LICENSE](LICENSE).
