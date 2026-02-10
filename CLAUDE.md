# Important information

## SSH

You have an SSH-MCP server connected and use SSH there. Log in as root.

## File transfer

Use scp -O via PowerShell to transfer files to the router. The bash tool cannot run scp directly due to quoting issues with hyphens in filenames. Use:
```powershell.exe -Command "scp -O '<local_path>' 'root@192.168.8.1:<remote_path>'"```

The SSH MCP tool has a 1000 character command limit, so it cannot be used for heredoc file transfers.

To push binaries to the modem (EP06) from the router, use adb:
```adb push /tmp/rayhunter-daemon /data/rayhunter/rayhunter-daemon```

After SCP'ing shell scripts from Windows, fix line endings on the router:
```sed -i 's/\r$//' /path/to/script```

## Router location

The router is located at 192.168.8.1

## GIT and GH

Commit and Push to the fork, also create a release according to the previous release versioning. See what files have been created in the previous release if you are ucertain. ```git``` and ```gh``` can be found in WSL. Use browser credential login if necessary.

## Linux

You have access to a linux file system by using ```WSL -d Ubuntu```

## Windows

You are running on a windows computer.

## npm

You have access to npm in cmd

## cargo

You have access to building in WSL. The default WSL distro is docker-desktop which has no bash — use Ubuntu explicitly:
```wsl -d Ubuntu -- bash -lc "cd /mnt/c/Users/chris/Documents/programming/rayhunter && cargo build-daemon-firmware-devel 2>&1"```

Two build profiles exist:
- `build-daemon-firmware` — uses ring TLS, smaller binary, slower build
- `build-daemon-firmware-devel` — uses rustcrypto, slightly larger binary, faster build

Both target `armv7-unknown-linux-musleabihf`. Output goes to:
`target/armv7-unknown-linux-musleabihf/firmware-devel/rayhunter-daemon`

## Web UI

The web UI (Svelte) is embedded in the daemon binary via `include_bytes!()` in `daemon/src/server.rs`. To deploy UI changes:
1. Build web UI: `cd daemon/web && npm run build` (works in regular bash/cmd)
2. Rebuild daemon in WSL (see cargo section above)
3. Push new binary to router via SCP, then to modem via `adb push`
4. Restart daemon on modem: `adb shell "/etc/init.d/rayhunter_daemon restart"`

## Deploying router-side scripts

Scripts go to `/usr/local/bin/` on the router. The boot script goes to `/etc/init.d/rayhunter-openwrt-boot`.
After deploying, restart the ntfy manager: `killall rayhunter-ntfy-manager.sh; /usr/local/bin/rayhunter-ntfy-manager.sh &`

## Git line endings (Windows)

When committing from Windows, files may have CRLF endings. Always check `git diff --stat` before staging — if diffs show hundreds of changed lines on files you only touched a few lines in, it's a line ending problem. Fix:
- Use `git checkout -- <file>` to restore the committed version
- Re-apply only the targeted edits using the Edit tool (it preserves existing line endings)
- Never use `sed -i 's/\r$//'` on files that were committed with CRLF — that creates a massive diff

## npm build on Windows

Use PowerShell for npm builds when the path has Windows-style separators:
```powershell.exe -Command "cd C:\Users\chris\Documents\programming\rayhunter\daemon\web; npm run build 2>&1"```

## gh release notes

Backticks in heredoc release notes get interpreted by bash. Use plain text, or create the release first and then fix notes with `gh release edit <tag> --notes "..."`.

## Installation scripts

When adding new scripts or features, remember to update BOTH:
- `dist/scripts/setup-rayhunter-glx750.ps1` — `$RayhunterFiles` array and `$ReleaseTag` default
- `dist/scripts/install-from-openwrt.sh` — helper scripts loop and generated `config.toml` analyzers

## Dashboard / Web UI architecture

- `app.html` wrapper uses `display: contents`, making its Tailwind margin/padding classes have no effect. Don't use negative margins on page components to compensate.
- SVG charts: avoid fixed `height` with `viewBox` — let the SVG auto-size from the viewBox aspect ratio. `preserveAspectRatio="none"` distorts text.
- The dashboard page lives at `/dashboard` (redirects to `/dashboard.html`). Built by SvelteKit adapter-static as a separate HTML file alongside `index.html`.

## API endpoints

- `/api/signal-quality` - GET, reads `/tmp/rayhunter-signal.json`, 503 if stale/missing
- `/api/temperature` - GET, reads `/tmp/rayhunter-temperature.json`, 503 if stale/missing
- `/api/analysis-counts/{name}` - lightweight JSON counts
- `/api/analysis-report/{name}` - full NDJSON report (heavy)
- `/api/test-warning` - POST to inject test warning event
- `/api/qmdl-manifest` - recording manifest with `current_entry.qmdl_size_bytes`

## Web UI pages

- `/` - main UI (index.html)
- `/dashboard` - full-screen dark-themed live monitoring dashboard (dashboard.html)

## Updating your knowledge

Update/append/change this file if you find anything new that works and is important for future know-how.