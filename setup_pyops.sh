#!/usr/bin/env bash
# setup_pyops.sh
# One-shot installer for:
#  - PyOps FastAPI (with streaming pip logs)
#  - code-server (VS Code in the browser)
#  - systemd services (or fallback runner if systemd unavailable e.g., some WSL setups)
# Safe for re-runs. Tested on Ubuntu 22.04+/24.04+ and WSL with systemd enabled.

set -Eeuo pipefail

### ---- Helpers ---------------------------------------------------------------

log()   { printf "\n[INFO] %s\n" "$*"; }
warn()  { printf "\n[WARN] %s\n" "$*" >&2; }
die()   { printf "\n[ERR ] %s\n" "$*" >&2; exit 1; }

have()  { command -v "$1" >/dev/null 2>&1; }

REAL_USER() {
  if [[ -n "${SUDO_USER-}" && "${SUDO_USER}" != "root" ]]; then
    printf "%s" "$SUDO_USER"
  else
    printf "%s" "$USER"
  fi
}

as_root() {
  # run a command with sudo if not root
  if [[ $EUID -ne 0 ]]; then
    sudo bash -c "$*"
  else
    bash -c "$*"
  fi
}

SYSTEMD_AVAILABLE() {
  # Consider systemd available if the directory exists and systemctl is usable
  [[ -d /run/systemd/system ]] && have systemctl
}

### ---- Vars ------------------------------------------------------------------

TARGET_USER="$(REAL_USER)"
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$USER_HOME" ]] || die "Could not resolve HOME for user $TARGET_USER"

PYOPS_DIR="$USER_HOME/pyops"
VENV_DIR="$USER_HOME/.venvs/pyops"
PY_BIN="$VENV_DIR/bin/python"
PIP_BIN="$VENV_DIR/bin/pip"

API_HOST="127.0.0.1"
API_PORT="8077"
CODE_HOST="127.0.0.1"
CODE_PORT="8080"

### ---- OS packages -----------------------------------------------------------

install_apt() {
  log "Installing system packages (Ubuntu)…"
  as_root "apt-get update -y"
  as_root "DEBIAN_FRONTEND=noninteractive apt-get install -y \
    python3 python3-venv python3-pip \
    curl ca-certificates psmisc build-essential jq"
}

install_code_server() {
  if have code-server; then
    log "code-server already installed."
    return 0
  fi
  log "Installing code-server…"
  # Official installer
  curl -fsSL https://code-server.dev/install.sh | bash || {
    warn "code-server install script failed; attempting apt-based install."
    # Fallback apt method (if script unavailable)
    as_root "curl -fsSL https://code-server.dev/install.sh | sh" || {
      die "Failed to install code-server"
    }
  }
}

### ---- App & venv ------------------------------------------------------------

write_app_py() {
  log "Writing $PYOPS_DIR/app.py …"
  mkdir -p "$PYOPS_DIR"
  # Write the FastAPI app with protected 'pyops' deletion + streaming endpoints
  cat >"$PYOPS_DIR/app.py" <<'PYOPS_APP'
from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import tempfile
import pathlib
from pathlib import Path
from typing import Iterator

from fastapi import FastAPI, HTTPException, Form, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import (
    HTMLResponse,
    JSONResponse,
    PlainTextResponse,
    StreamingResponse,
)
from pydantic import BaseModel, constr

# -------------------------------------------------------------------
# FastAPI app (must exist before any @app.* decorators)
# -------------------------------------------------------------------
app = FastAPI()

# CORS for local extension/UI
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# -------------------------------------------------------------------
# Paths / config
# -------------------------------------------------------------------
BASE = pathlib.Path.home()
PRIMARY = BASE / "envs"  # default create target
ROOTS = [PRIMARY, BASE / ".venvs", BASE / ".virtualenvs"]
PRIMARY.mkdir(exist_ok=True)

NameStr = constr(pattern=r"^[A-Za-z0-9_-]{1,32}$")


# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------
def _safe(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _env_dir(name: str) -> pathlib.Path | None:
    for root in ROOTS:
        p = root / name
        if p.is_dir():
            return p
    return None


def list_envs() -> list[str]:
    names = set()
    for root in ROOTS:
        if root.exists():
            for p in root.iterdir():
                if p.is_dir():
                    names.add(p.name)
    return sorted(names)


def _py_path(env: str) -> pathlib.Path:
    d = _env_dir(env) or (PRIMARY / env)
    return d / "bin" / "python"


def _pip_path(env: str) -> pathlib.Path:
    d = _env_dir(env) or (PRIMARY / env)
    return d / "bin" / "pip"


def _pip_install_reqs(env: str, reqs_path: pathlib.Path) -> subprocess.CompletedProcess:
    out = subprocess.run(
        [str(_pip_path(env)), "install", "-r", str(reqs_path)],
        capture_output=True,
        text=True,
    )
    return out


def _delete_env(name: str) -> tuple[bool, str]:
    # Safety: never delete the working "pyops" venv
    if name == "pyops":
        return False, "refusing to delete protected environment: pyops"

    d = _env_dir(name) or (PRIMARY / name)
    try:
        if not d.exists():
            return False, f"{name}: not found"
        if not d.is_dir():
            return False, f"{name}: not a directory"
        if d.is_symlink():
            return False, f"{name}: symlink not allowed"
        if not any(d.resolve().is_relative_to(r.resolve()) for r in ROOTS):
            return False, "refuses to delete: outside allowed roots"
        shutil.rmtree(d)
        return True, f"deleted: {name}"
    except Exception as e:  # pragma: no cover
        return False, f"error deleting {name}: {e}"


def _stream_cmd(args: list[str], cwd: str | None = None) -> Iterator[str]:
    """Run a command and yield combined stdout/stderr line-by-line."""
    env = os.environ.copy()
    # make pip chatty and line-oriented when not a TTY
    env["PYTHONUNBUFFERED"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"
    env["PIP_PROGRESS_BAR"] = "off"
    env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"

    quoted = " ".join(shlex.quote(a) for a in args)
    yield f"$ {quoted}\n"

    proc = subprocess.Popen(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,  # line-buffered
        cwd=cwd,
        env=env,
    )

    assert proc.stdout is not None
    for line in proc.stdout:
        # ensure every chunk ends with newline for the client appender
        yield line if line.endswith("\n") else (line + "\n")

    rc = proc.wait()
    yield f"\n[exit {rc}]\n"


# -------------------------------------------------------------------
# Models
# -------------------------------------------------------------------
class Snippet(BaseModel):
    env: str
    code: str
    args: str | None = ""


class VenvReq(BaseModel):
    name: NameStr


class PipReq(BaseModel):
    env: NameStr
    pkgs: list[str] | str


class RunReq(BaseModel):
    env: NameStr
    path: str
    args: list[str] | str | None = None


# -------------------------------------------------------------------
# Basic routes / UI
# -------------------------------------------------------------------
HTML_HEAD = """<!doctype html><meta charset="utf-8"><title>PyOps</title>
<style>
body{font:14px system-ui,Segoe UI,Roboto,Ubuntu,sans-serif;margin:24px}
section{border:1px solid #ddd;border-radius:10px;padding:16px;margin:12px 0}
input,button,select{padding:.5rem .6rem;border-radius:8px;border:1px solid #bbb}button{cursor:pointer}
code{background:#f5f5f5;padding:2px 6px;border-radius:6px}
pre{white-space:pre-wrap;word-break:break-word;overflow-wrap:anywhere;max-height:420px;overflow:auto}
</style>"""


@app.get("/api/health")
def health():
    return {"ok": True, "roots": [str(r) for r in ROOTS]}


@app.get("/", response_class=HTMLResponse)
def index():
    envs = list_envs()
    opts = (
        "".join(f"<option>{e}</option>" for e in envs)
        or "<option value='' disabled>(no envs)</option>"
    )
    return (
        HTML_HEAD
        + f"""
<h1>PyOps</h1>

<section><h2>Create virtual environment</h2>
<form method="post" action="/create-venv">
<input name="name" pattern="[A-Za-z0-9_-]{{1,32}}" required>
<button type="submit">Create</button></form></section>

<section><h2>Install packages (pip)</h2>
<form method="post" action="/pip-install">
<select name="env">{opts}</select>
<input name="pkgs" placeholder="requests numpy jinja2" required>
<button type="submit">Install</button></form></section>

<section><h2>Install from requirements.txt</h2>
<form method="post" action="/pip-install-reqs" enctype="multipart/form-data">
<select name="env">{opts}</select>
<input type="file" name="file" accept=".txt,.in,.reqs,.cfg,.ini,.pip">
<span>or path:</span> <input name="path" placeholder="projects/requirements.txt">
<button type="submit">Run</button></form>
<p><small>Tip: if both file and path are supplied, the uploaded file wins.</small></p>
</section>

<section><h2>Run script</h2>
<form method="post" action="/run">
<select name="env">{opts}</select>
<input name="path" placeholder="projects/foo.py" required>
<input name="args" placeholder="--flag 1">
<button type="submit">Run</button></form></section>

<section><h2>Delete environment</h2>
<form method="post" action="/delete-venv">
<select name="name">{opts}</select>
<button style="background:#fee;border-color:#f99" type="submit">Delete</button>
</form></section>"""
    )


# ---------------- Snippet runner (used by DevDock) ----------------
@app.post("/run-snippet", response_class=PlainTextResponse)
def run_snippet(s: Snippet):
    envdir = Path.home() / "envs" / s.env
    py = envdir / "bin" / "python"
    if not py.exists():
        raise HTTPException(status_code=400, detail=f"env not found: {s.env}")

    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(s.code)
        tmp = f.name

    try:
        proc = subprocess.run(
            [str(py), tmp, *shlex.split(s.args or "")],
            capture_output=True,
            text=True,
            timeout=180,
        )
        return (proc.stdout or "") + (proc.stderr or "")
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


# ---------------- HTML form handlers ----------------
@app.post("/create-venv", response_class=HTMLResponse)
def create_venv(name: str = Form(...)):
    tgt = PRIMARY / name
    tgt.parent.mkdir(parents=True, exist_ok=True)
    if tgt.exists():
        return (
            HTML_HEAD
            + f"<p>Env <code>{_safe(name)}</code> already exists ({_safe(str(tgt))}).</p><p><a href='/'>Back</a></p>"
        )
    out = subprocess.run(
        ["/usr/bin/python3", "-m", "venv", str(tgt)],
        capture_output=True,
        text=True,
    )
    return (
        HTML_HEAD
        + f"<h2>Created at {_safe(str(tgt))}</h2><pre>{_safe(out.stdout+out.stderr)}</pre><p><a href='/'>Back</a></p>"
    )


@app.post("/pip-install", response_class=HTMLResponse)
def pip_install(env: str = Form(...), pkgs: str = Form(...)):
    out = subprocess.run(
        [str(_pip_path(env)), "install", *shlex.split(pkgs)],
        capture_output=True,
        text=True,
    )
    return (
        HTML_HEAD
        + f"<h2>pip install output</h2><pre>{_safe(out.stdout+out.stderr)}</pre><p><a href='/'>Back</a></p>"
    )


@app.post("/pip-install-reqs", response_class=HTMLResponse)
def pip_install_reqs_html(
    env: str = Form(...), file: UploadFile = File(None), path: str = Form(None)
):
    if file is not None:
        with tempfile.NamedTemporaryFile(delete=False, suffix=".txt") as tmp:
            tmp.write(file.file.read())
            tmp_path = pathlib.Path(tmp.name)
        out = _pip_install_reqs(env, tmp_path)
        try:
            tmp_path.unlink(missing_ok=True)
        except Exception:
            pass
    else:
        if not path:
            return HTML_HEAD + "<p>No file or path provided.</p><p><a href='/'>Back</a></p>"
        req = (BASE / path).expanduser()
        out = _pip_install_reqs(env, req)
    return (
        HTML_HEAD
        + f"<h2>pip -r output</h2><pre>{_safe(out.stdout+out.stderr)}</pre><p><a href='/'>Back</a></p>"
    )


@app.post("/run", response_class=HTMLResponse)
def run(env: str = Form(...), path: str = Form(...), args: str = Form("")):
    script = (BASE / path).expanduser()
    out = subprocess.run(
        [str(_py_path(env)), str(script), *shlex.split(args or "")],
        capture_output=True,
        text=True,
        cwd=str(script.parent),
    )
    return (
        HTML_HEAD
        + f"<h2>Run output</h2><pre>{_safe(out.stdout+out.stderr)}</pre><p><a href='/'>Back</a></p>"
    )


@app.post("/delete-venv", response_class=HTMLResponse)
def delete_venv_html(name: str = Form(...)):
    ok, msg = _delete_env(name)
    return HTML_HEAD + f"<h2>Delete</h2><pre>{_safe(msg)}</pre><p><a href='/'>Back</a></p>"


# ---------------- JSON API ----------------
@app.get("/api/envs")
def api_list_envs():
    return {"envs": list_envs(), "roots": [str(r) for r in ROOTS]}


@app.post("/api/create-venv")
def api_create_venv(req: VenvReq):
    tgt = PRIMARY / req.name
    tgt.parent.mkdir(parents=True, exist_ok=True)
    if tgt.exists():
        return {"ok": True, "note": "exists", "env": req.name, "path": str(tgt)}
    out = subprocess.run(
        ["/usr/bin/python3", "-m", "venv", str(tgt)],
        capture_output=True,
        text=True,
    )
    return {
        "ok": out.returncode == 0,
        "env": req.name,
        "path": str(tgt),
        "stdout": out.stdout,
        "stderr": out.stderr,
    }


@app.post("/api/pip-install")
def api_pip_install(req: PipReq):
    pkgs = req.pkgs if isinstance(req.pkgs, list) else shlex.split(req.pkgs)
    out = subprocess.run(
        [str(_pip_path(req.env)), "install", *pkgs], capture_output=True, text=True
    )
    return {"ok": out.returncode == 0, "stdout": out.stdout, "stderr": out.stderr}


@app.post("/api/pip-install-reqs")
async def api_pip_install_reqs(
    env: NameStr = Form(...), file: UploadFile = File(None), path: str = Form(None)
):
    if file is not None:
        with tempfile.NamedTemporaryFile(delete=False, suffix=".txt") as tmp:
            b = await file.read()
            tmp.write(b)
            tmp_path = pathlib.Path(tmp.name)
        out = _pip_install_reqs(env, tmp_path)
        try:
            tmp_path.unlink(missing_ok=True)
        except Exception:
            pass
    else:
        if not path:
            return JSONResponse({"ok": False, "stderr": "no file or path"})
        req = (BASE / path).expanduser()
        out = _pip_install_reqs(env, req)
    return {"ok": out.returncode == 0, "stdout": out.stdout, "stderr": out.stderr}


@app.post("/api/run")
def api_run(req: RunReq):
    script = (BASE / req.path).expanduser()
    args = (
        req.args
        if isinstance(req.args, list)
        else (shlex.split(req.args) if req.args else [])
    )
    out = subprocess.run(
        [str(_py_path(req.env)), str(script), *args],
        capture_output=True,
        text=True,
        cwd=str(script.parent),
    )
    return {
        "ok": out.returncode == 0,
        "code": out.returncode,
        "stdout": out.stdout,
        "stderr": out.stderr,
    }


@app.post("/api/delete-venv")
def api_delete_venv(req: VenvReq):
    ok, msg = _delete_env(req.name)
    return JSONResponse({"ok": ok, "message": msg})


# ---------------- STREAMING API (for live install output) ----------------
@app.post("/api/pip-install-stream")
def api_pip_install_stream(req: PipReq):
    env_dir = _env_dir(req.env)
    if not env_dir or not (_pip_path(req.env)).exists():
        raise HTTPException(status_code=400, detail=f"env not found: {req.env}")

    pkgs = req.pkgs if isinstance(req.pkgs, list) else shlex.split(req.pkgs)
    args = [str(_pip_path(req.env)), "install", *pkgs]

    return StreamingResponse(
        _stream_cmd(args),
        media_type="text/plain",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.post("/api/pip-install-reqs-stream")
async def api_pip_install_reqs_stream(
    env: NameStr = Form(...), file: UploadFile = File(None), path: str = Form(None)
):
    env_dir = _env_dir(env)
    if not env_dir or not (_pip_path(env)).exists():
        raise HTTPException(status_code=400, detail=f"env not found: {env}")

    req_path: pathlib.Path | None = None
    if file is not None:
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".txt")
        tmp.write(await file.read())
        tmp.flush()
        tmp.close()
        req_path = pathlib.Path(tmp.name)
    elif path:
        req_path = (BASE / path).expanduser()
    else:
        raise HTTPException(status_code=400, detail="no file or path provided")

    args = [str(_pip_path(env)), "install", "-r", str(req_path)]

    def gen():
        try:
            yield from _stream_cmd(args)
        finally:
            if file is not None:
                try:
                    req_path.unlink(missing_ok=True)  # type: ignore[union-attr]
                except Exception:
                    pass

    return StreamingResponse(
        gen(),
        media_type="text/plain",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
PYOPS_APP
  chmod 644 "$PYOPS_DIR/app.py"
}

ensure_venv() {
  log "Creating venv at $VENV_DIR …"
  mkdir -p "$(dirname "$VENV_DIR")"
  if [[ ! -x "$PY_BIN" ]]; then
    /usr/bin/python3 -m venv "$VENV_DIR"
  fi

  log "Upgrading pip/setuptools/wheel …"
  "$PIP_BIN" install -U pip setuptools wheel >/dev/null
}

install_pydeps() {
  log "Installing Python deps (fastapi, uvicorn[standard], python-multipart)…"
  "$PIP_BIN" install -U "fastapi>=0.114" "uvicorn[standard]>=0.30" "python-multipart>=0.0.9" >/dev/null
}

### ---- systemd units (fixed paths, no WorkingDirectory) ----------------------

write_units() {
  log "Writing systemd service: /etc/systemd/system/pyops@.service"
  as_root "tee /etc/systemd/system/pyops@.service >/dev/null" <<'EOF'
[Unit]
Description=PyOps (venv/pip/run web UI) for user %i
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=%i
# Avoid CHDIR problems: don't set WorkingDirectory
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONIOENCODING=utf-8
ExecStartPre=-/usr/bin/fuser -k 8077/tcp
# Use explicit /home/%i paths; --app-dir points at the app without chdir
ExecStart=/home/%i/.venvs/pyops/bin/python -m uvicorn app:app --app-dir /home/%i/pyops --host 127.0.0.1 --port 8077
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  log "Writing systemd service: /etc/systemd/system/code-server@.service"
  as_root "tee /etc/systemd/system/code-server@.service >/dev/null" <<'EOF'
[Unit]
Description=code-server (VS Code in browser) for user %i
After=network.target

[Service]
Type=simple
User=%i
# Avoid CHDIR; give code-server a starting folder explicitly
ExecStart=/usr/bin/code-server --bind-addr 127.0.0.1:8080 --auth none --disable-telemetry /home/%i
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

enable_services() {
  if SYSTEMD_AVAILABLE; then
    log "Reloading systemd and enabling services at boot…"
    as_root "systemctl daemon-reload"
    as_root "systemctl enable --now pyops@${TARGET_USER}"
    as_root "systemctl enable --now code-server@${TARGET_USER}"
  else
    warn "systemd not available (common on some WSL setups without systemd). Using fallback launcher."
    fallback_launch
  fi
}

fallback_launch() {
  # Start processes in the background for this session (no autostart)
  log "Starting PyOps API in background (fallback)…"
  nohup "$PY_BIN" -m uvicorn app:app --app-dir "$PYOPS_DIR" --host "$API_HOST" --port "$API_PORT" \
    >"$PYOPS_DIR/pyops.log" 2>&1 & disown || warn "Failed to start PyOps in fallback mode."

  if have code-server; then
    log "Starting code-server in background (fallback)…"
    nohup /usr/bin/code-server --bind-addr "$CODE_HOST:$CODE_PORT" --auth none --disable-telemetry "$USER_HOME" \
      >"$USER_HOME/.code-server.log" 2>&1 & disown || warn "Failed to start code-server in fallback mode."
  else
    warn "code-server not installed; skipping fallback start."
  fi

  warn "Autostart is not configured without systemd. On WSL, enable systemd in /etc/wsl.conf and restart the distro."
}

### ---- Health checks ---------------------------------------------------------

wait_for_api() {
  log "Checking API health…"
  local tries=40
  local url="http://${API_HOST}:${API_PORT}/api/health"
  until curl -fsS "$url" >/dev/null 2>&1; do
    ((tries--)) || { warn "PyOps API not responding yet. Check logs."; return 1; }
    sleep 0.5
  done
  curl -fsS "$url" && echo
  return 0
}

### ---- Main ------------------------------------------------------------------

main() {
  install_apt
  install_code_server
  write_app_py
  ensure_venv
  install_pydeps

  # Permissions are important if script was run with sudo
  chown -R "$TARGET_USER":"$TARGET_USER" "$USER_HOME/.venvs" "$PYOPS_DIR" 2>/dev/null || true

  write_units
  enable_services

  wait_for_api || {
    warn "PyOps API not ready. Tail logs with:"
    echo "  sudo journalctl -u pyops@${TARGET_USER} -f"
  }

  log "code-server should be at http://${CODE_HOST}:${CODE_PORT}/ (auth disabled, loopback-only)."

  log "Done. Defaults match your DevDock extension:"
  printf "  API:  http://%s:%s\n" "$API_HOST" "$API_PORT"
  printf "  Code: http://%s:%s\n\n" "$CODE_HOST" "$CODE_PORT"

  cat <<EOF
Management:
  Restart API:   sudo systemctl restart pyops@${TARGET_USER}
  Follow logs:   sudo journalctl -u pyops@${TARGET_USER} -f
  Restart Code:  sudo systemctl restart code-server@${TARGET_USER}
EOF
}

main "$@"
