# swarm-code

A terminal coding agent. Multi-agent, BYOM (bring your own model), written in
`sw` on the [swarmrt](https://github.com/skyblanket/swarmrt) BEAM-shaped C
runtime. Single ~3 MB native binary, no Node/Python/Electron.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/skyblanket/swarm-code/main/scripts/install.sh | sh
```

That drops `swarm` into `~/.local/bin` and writes a config stub at
`~/.swarm-code/settings.json`. Open it, paste your API key, then:

```bash
swarm
```

Default model is Kimi K2.6 (256K context). Anything OpenAI-compatible works —
edit `endpoint` + `model` in `settings.json`.

### Supported platforms

Same story as Claude Code: **macOS, Linux, and WSL2 are first-class.
Native Windows is not supported** — there's no `swarm.exe`, no plan
for one. Windows users run swarm-code inside WSL2.

| Platform | Binary | Notes |
|----------|--------|-------|
| macOS Apple Silicon | `swarm-darwin-arm64` | |
| Linux x86_64 | `swarm-linux-x86_64` | covers WSL2 too |
| Linux ARM64 | `swarm-linux-arm64` | |
| macOS Intel | — | build from source (see below) |
| Windows | — | install WSL2, then run the installer |

### Windows users — set up WSL2 first

In an admin PowerShell:

```powershell
wsl --install      # one-time, ~2 min, may reboot
```

Then open Ubuntu from the Start menu and run the standard installer
inside that Ubuntu session:

```bash
curl -fsSL https://raw.githubusercontent.com/skyblanket/swarm-code/main/scripts/install.sh | sh
swarm
```

Your Windows drives are reachable from inside WSL at `/mnt/c`, `/mnt/d`,
etc., so swarm can edit files anywhere on the machine.

## Build from source

You'll need a C compiler, `libsqlite3-dev`, `libssl-dev`, `zlib1g-dev`
(Linux) or `brew install sqlite3` (macOS).

```bash
git clone https://github.com/skyblanket/swarmrt   ../swarmrt
git clone https://github.com/skyblanket/swarm-code
cd ../swarmrt && make swc libswarmrt
cd ../swarm-code && make
./bin/swarm-code
```

## Configuration

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
merge over the user-global file.

## License

MIT. See [LICENSE](LICENSE) (or fall back to swarmrt's MIT terms until
a separate file is added).
