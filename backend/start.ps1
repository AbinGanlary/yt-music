# Starts the YT Music backend on localhost only; Tailscale Serve exposes it over HTTPS to your tailnet.
$dir = $PSScriptRoot
$env:APP_TOKEN = (Get-Content (Join-Path $dir 'token.txt') -Raw).Trim()
Set-Location $dir
& "$dir\.venv\Scripts\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8000
