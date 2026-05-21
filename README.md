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

| Platform | Binary | Notes |
|----------|--------|-------|
| macOS Apple Silicon | `swarm-darwin-arm64` | |
| macOS Intel | `swarm-darwin-x86_64` | |
| Linux x86_64 | `swarm-linux-x86_64` | also covers WSL2 |
| Linux ARM64 | `swarm-linux-arm64` | |
| Windows | — | use WSL2, run the install above |

### Windows (WSL2)

```powershell
wsl --install      # one-time, in PowerShell as admin
```

Reboot if Windows asks. Open Ubuntu from the Start menu, then run the same
`curl … | sh` command above.

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
