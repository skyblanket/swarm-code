# swarm-code — Windows installer stub
#
# Usage:   irm https://raw.githubusercontent.com/skyblanket/swarm-code/main/scripts/install.ps1 | iex
#
# swarmrt (the runtime swarm-code is built on) doesn't have a native
# Windows port yet — it relies on POSIX APIs that don't map cleanly to
# Win32. WSL2 runs the Linux binary natively and is the supported path.

Write-Host ""
Write-Host "swarm-code on Windows" -ForegroundColor Cyan
Write-Host "─────────────────────"
Write-Host ""
Write-Host "Native Windows isn't supported yet. The fastest path is WSL2:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. Install WSL2 (one-time, ~2 min):" -ForegroundColor White
Write-Host "     wsl --install" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. Reboot if Windows tells you to."
Write-Host ""
Write-Host "  3. Open Ubuntu (Start menu → Ubuntu), then run:" -ForegroundColor White
Write-Host "     curl -fsSL https://raw.githubusercontent.com/skyblanket/swarm-code/main/scripts/install.sh | sh" -ForegroundColor Gray
Write-Host ""
Write-Host "  4. swarm runs inside WSL but can edit any file on your"
Write-Host "     Windows drives via /mnt/c, /mnt/d, etc."
Write-Host ""

if (Get-Command wsl -ErrorAction SilentlyContinue) {
    Write-Host "(WSL is already installed on this machine — you can skip step 1.)" -ForegroundColor Green
    Write-Host ""
}
