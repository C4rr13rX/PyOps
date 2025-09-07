# PyOps
Set up a Python API and code-server (VSCode IDE in browser) both as service in Ubuntu. Designed especially for Ubuntu in WSL2 in Windows 11.

# DevDock + PyOps Installer

This repo provides a **one-shot installer** (`setup_pyops.sh`) that sets up:

* **PyOps** — a FastAPI service for managing Python virtualenvs, installing packages (with **live streaming pip logs**), running scripts, and executing code snippets.
* **code-server** — VS Code in the browser, bound to `127.0.0.1:8080` with auth disabled (loopback only).
* **systemd services** for both, enabled at boot on Ubuntu (with a **WSL2 fallback** when systemd isn’t available).

It’s safe to re-run. The script handles upgrades, idempotency, and common pitfalls we hit during development (e.g., working directory and permission gotchas with systemd).

---

## What the script does

* Creates `~/pyops/app.py` (or updates it) with:

  * REST + minimal HTML UI
  * JSON and **streaming** endpoints for pip installs
  * A **protected** environment rule (won’t let you delete the `pyops` venv by accident)
* Creates a Python venv at `~/.venvs/pyops` and installs:

  * `fastapi`, `uvicorn[standard]`, `python-multipart`
* Installs **code-server** (if missing).
* Writes and enables these **systemd units**:

  * `/etc/systemd/system/pyops@.service`
  * `/etc/systemd/system/code-server@.service`
* Starts services on:

  * **PyOps API:** `http://127.0.0.1:8077`
  * **code-server:** `http://127.0.0.1:8080`
* Falls back to a **non-systemd launcher** on platforms without systemd (e.g., some WSL setups) so you can still run everything today.

---

## Requirements

* Ubuntu 22.04+ / 24.04+ (native or **WSL2 on Windows 11**)
* `bash`, `curl`, `sudo`, `python3`, `python3-venv`
  (the script installs missing Ubuntu packages automatically)

---

## Quick start

1. Put `setup_pyops.sh` at the root of your home directory (or anywhere you prefer).

2. Run it:

   ```bash
   chmod +x setup_pyops.sh && ./setup_pyops.sh
   ```

3. Verify:

   ```bash
   # PyOps API health
   curl -fsS http://127.0.0.1:8077/api/health | jq

   # code-server (open in your browser)
   xdg-open http://127.0.0.1:8080/ 2>/dev/null || echo "Open http://127.0.0.1:8080/"
   ```

If systemd is available, services will also **start at boot**.
If systemd isn’t available, the script will **launch both in the background** for your current session and tell you how to enable systemd (WSL2 notes below).

---

## Managing the services (Ubuntu with systemd)

```bash
# PyOps API
sudo systemctl restart pyops@$USER
sudo journalctl -u pyops@$USER -f

# code-server
sudo systemctl restart code-server@$USER
sudo journalctl -u code-server@$USER -f

# Enable at boot (done by the script, but handy to know)
sudo systemctl enable pyops@$USER
sudo systemctl enable code-server@$USER
```

> The units intentionally **do not set** `WorkingDirectory` to avoid “CHDIR Permission denied” issues.
> `uvicorn` is launched with `--app-dir /home/<user>/pyops` instead.

---

## Endpoints you get

* **HTML/Minimal UI**

  * `GET /` — simple web UI for create/installs/run/delete
* **Health**

  * `GET /api/health`
* **Envs**

  * `GET /api/envs`
  * `POST /api/create-venv` — `{ "name": "myenv" }`
  * `POST /api/delete-venv` — `{ "name": "myenv" }`
    (refuses to delete the protected `pyops` venv)
* **pip installs (buffered)**

  * `POST /api/pip-install` — `{ "env":"myenv", "pkgs":"requests numpy" }`
  * `POST /api/pip-install-reqs` — form `env=...` and `file=<upload>` or `path=...`
* **pip installs (streaming)**

  * `POST /api/pip-install-stream` — `{ "env":"myenv", "pkgs":"requests numpy" }`
  * `POST /api/pip-install-reqs-stream` — form `env=...` plus `file` or `path`
* **Run script**

  * `POST /api/run` — `{ "env":"myenv", "path":"projects/foo.py", "args":"--flag 1" }`
* **Snippet**

  * `POST /run-snippet` — Plain text output; body: `{ env, code, args }`

**Security note:** everything binds to **127.0.0.1** only.

---

## Using with the DevDock browser extension

The installer uses these defaults:

* API: `http://127.0.0.1:8077`
* Code: `http://127.0.0.1:8080`

Those match DevDock’s defaults. If you change ports in your extension, keep them in sync.

---

## Ubuntu on WSL2 (Windows 11)

The script supports WSL2. There are two paths:

### 1) **WSL2 with systemd enabled** (recommended)

Enable systemd once and everything behaves like native Ubuntu (boot-time services):

1. In your WSL distro, edit `/etc/wsl.conf`:

   ```ini
   [boot]
   systemd=true
   ```

2. Restart WSL from PowerShell:

   ```powershell
   wsl --shutdown
   ```

3. Re-open the Ubuntu terminal and run the installer:

   ```bash
   chmod +x setup_pyops.sh && ./setup_pyops.sh
   ```

### 2) **WSL2 without systemd**

If systemd isn’t available, the script **auto-falls back** to launching both processes in the background for your current session. You won’t get auto-start at boot until you enable systemd (see above). The script tells you where logs go and how to re-start manually.

---

## Troubleshooting

* **API failing to start?**

  * Check logs:

    ```bash
    sudo journalctl -u pyops@$USER -e --no-pager
    ```

  * Confirm the venv exists and is owned by your user:

    ```bash
    ls -ld ~/.venvs/pyops
    ```

* **code-server not reachable?**

  * Make sure nothing else is bound to `127.0.0.1:8080`.
  * Logs:

    ```bash
    sudo journalctl -u code-server@$USER -e --no-pager
    ```

* **WSL2 can’t enable systemd?**

  * Ensure you edited `/etc/wsl.conf` inside the **Linux** distro, then ran `wsl --shutdown` in **PowerShell**, and reopened Ubuntu.

---

## Uninstall

```bash
# Stop and disable services
sudo systemctl disable --now pyops@$USER || true
sudo systemctl disable --now code-server@$USER || true

# Remove units
sudo rm -f /etc/systemd/system/pyops@.service
sudo rm -f /etc/systemd/system/code-server@.service
sudo systemctl daemon-reload

# Remove app + venv (keep anything else you care about)
rm -rf ~/pyops ~/.venvs/pyops
```

> The API itself already refuses to delete the protected `pyops` environment via its HTTP delete endpoint, but you can remove it manually as shown above.

---

## Security

* Both services bind to **loopback** only.
* code-server is started with **`--auth none`** because it’s local-only. If you expose it beyond loopback, **enable auth**.
* The PyOps API can **create/delete venvs and run code** on your machine. Keep it local or put it behind proper auth/reverse-proxy if you ever expose it.

---

## License

MIT. Contributions and PRs welcome.
