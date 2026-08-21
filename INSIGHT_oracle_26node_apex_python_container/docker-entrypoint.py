#!/usr/bin/env python3
"""Start the AI chat proxy, render the nginx config, then exec nginx.

Written in Python rather than shell because the combined image is based on
python:3.12-slim: the interpreter is already present, so this needs no
extra package (envsubst would mean pulling in gettext-base).

Environment:
  ORDS_BASE_URL   scheme://host of the ORDS server. Defaults to
                  DEFAULT_ORDS_BASE_URL below, so this only needs setting
                  to point a container at a different database. A path is
                  accepted and stripped: nginx appends the request URI,
                  which already carries /ords/admin/..., so a base with a
                  path would produce a doubled URL.
  ORDS_API_KEY    api_key for the ORDS modules. Only needed if
                  iteria_ai.api_configuration holds an active key. It is
                  read from the environment and never stored in this file:
                  the repository is public, and the image is built from it,
                  so a hardcoded key would be readable by anyone and would
                  travel inside every pull of the image.

  CHAT_PROXY_DISABLE  Set to 1 to skip starting the AI chat proxy. The
                  site serves normally without it; /api/chat then returns
                  502. Useful when a container is deployed somewhere the
                  Generative AI policy does not reach.

Two processes run here, so this script stays PID 1 and supervises both
rather than exec-ing nginx over itself:

  nginx        the reason the container exists. When it exits, so does the
               container, with its exit code.
  chat proxy   restarted if it dies, but its death is never fatal --
               /api/chat degrades to 502 while the questionnaire keeps
               working. An AI panel that is down is a degraded feature; a
               container that will not serve the questionnaire is an outage.

Being PID 1 also means SIGTERM arrives here on `docker stop`, and is
forwarded to both children for an orderly shutdown, and that any orphaned
process gets reaped instead of accumulating as a zombie.

If /ords/ is unconfigured the rest of the site still serves -- an
unreachable database is not a reason to take the whole container down.

The DNS resolver is read from /etc/resolv.conf, because nginx does not
consult it on its own and needs an explicit `resolver` directive before it
will resolve names at request time.
"""

import os
import re
import signal
import subprocess
import sys
import threading
import time

TEMPLATE = "/etc/nginx/templates/default.conf.template"
OUTPUT = "/etc/nginx/conf.d/default.conf"
FALLBACK_RESOLVER = "127.0.0.11"  # Docker's embedded DNS

CHAT_PROXY_SCRIPT = "/app/INSIGHT_chat_proxy.py"
CHAT_PROXY_PORT = "5001"          # must match the /api/chat upstream in the
                                  # nginx template
CHAT_PROXY_MIN_BACKOFF = 2        # seconds
CHAT_PROXY_MAX_BACKOFF = 60
SHUTDOWN_GRACE = 10               # seconds to wait for a child to stop

_shutting_down = threading.Event()
_children = []                    # Popen objects, appended as they start
_children_lock = threading.Lock()

# The database this image is normally deployed against. A hostname is not a
# credential -- the api_key is what controls access -- so baking it in is
# safe and means the container needs no configuration to work.
DEFAULT_ORDS_BASE_URL = (
    "https://g654ecb02dc8fb5-zspniy715u9q85u2.adb.ap-mumbai-1.oraclecloudapps.com"
)

# ---------------------------------------------------------------------------
# REMOVE BEFORE THIS HOLDS REAL CLIENT DATA
# ---------------------------------------------------------------------------
# Baked in at the project owner's instruction so the container needs no
# configuration during build-out. This repository is public, so treat this
# value as disclosed: it is the only access control in front of the ORDS
# modules, which can read and write every questionnaire table.
#
# Deleting these lines later does NOT undo the disclosure -- the value stays
# in git history and in every image built from it. To retire it you must
# ROTATE the key:
#
#   UPDATE iteria_ai.api_configuration SET api_key = '<new value>'
#    WHERE is_active = 'Y';
#
# and then supply the replacement via the ORDS_API_KEY environment variable
# instead of this constant. The env var already takes precedence, so that
# switch needs no code change.
DEFAULT_ORDS_API_KEY = "vld8x2k9mPqR7sNjT4hW"


def detect_resolver(path="/etc/resolv.conf"):
    """First nameserver in resolv.conf, or Docker's embedded DNS."""
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                parts = line.split()
                if len(parts) >= 2 and parts[0] == "nameserver":
                    return parts[1]
    except OSError:
        pass
    return FALLBACK_RESOLVER


def sanitize_base_url(raw):
    """Reduce to a bare scheme://host[:port].

    The value lands inside an nginx directive, so anything outside that
    shape is rejected rather than allowed to corrupt the config. A path is
    tolerated and dropped instead of being an error: proxy_pass appends the
    request URI, which already begins /ords/admin/..., so keeping a path
    here would produce /ords/admin/ords/admin/... -- and pasting the full
    ORDS base URL is the obvious thing to do.
    """
    value = (raw or "").strip()
    if not value:
        return ""
    m = re.match(r"^(https?://[A-Za-z0-9.\-]+(?::\d+)?)(/.*)?$", value)
    if not m:
        sys.exit(f"ORDS_BASE_URL must look like https://host[:port], got: {value!r}")
    if m.group(2) and m.group(2).strip("/"):
        print(
            f"[entrypoint] ignoring path {m.group(2)!r} on ORDS_BASE_URL; "
            "the request URI already supplies it",
            flush=True,
        )
    return m.group(1)


def sanitize_api_key(raw):
    value = (raw or "").strip()
    if value and not re.match(r"^[A-Za-z0-9._\-]+$", value):
        sys.exit("ORDS_API_KEY contains characters that are not safe in a URL.")
    return value


def spawn(argv, env=None):
    """Start a child and register it for shutdown."""
    proc = subprocess.Popen(argv, env=env)  # noqa: S603 -- fixed argv, no shell
    with _children_lock:
        _children.append(proc)
    return proc


def request_stop(signum=None, _frame=None):
    """Signal every child to stop. Registered as the SIGTERM/SIGINT handler.

    This only sends signals -- it deliberately does NOT wait for anything.
    Signal handlers run on the main thread, which is normally blocked inside
    nginx.wait(); Popen holds a non-reentrant lock while waiting, so calling
    wait() on that same object from the handler can never acquire it and
    would stall for the whole grace period before killing a child that had
    already exited cleanly. Waiting belongs in reap_children(), which runs
    after wait() has returned and released the lock.

    Idempotent: a second signal during shutdown is a no-op, which is what an
    impatient second Ctrl-C or a stop timeout produces.
    """
    if _shutting_down.is_set():
        return
    _shutting_down.set()
    if signum is not None:
        print(f"[entrypoint] received signal {signum}; stopping children", flush=True)
    with _children_lock:
        children = list(_children)
    for proc in children:
        try:
            proc.terminate()
        except (OSError, ProcessLookupError):
            pass  # already gone


def reap_children():
    """Wait for the stopped children, killing any that overstay the grace."""
    with _children_lock:
        children = list(_children)
    for proc in children:
        try:
            proc.wait(timeout=SHUTDOWN_GRACE)
        except subprocess.TimeoutExpired:
            print(
                f"[entrypoint] pid {proc.pid} ignored SIGTERM after "
                f"{SHUTDOWN_GRACE}s; killing",
                flush=True,
            )
            proc.kill()


def supervise_chat_proxy(script=CHAT_PROXY_SCRIPT):
    """Run the chat proxy in the background, restarting it if it exits.

    Restarts are capped by exponential backoff so a proxy that cannot start
    at all -- missing OCI policy, say -- produces a slow trickle of log lines
    rather than a hot loop burning the container's CPU.

    Nothing here can stop nginx from starting: a failure to launch is logged
    and the thread ends. That is deliberate. An AI panel that is down is a
    degraded feature; a container that will not serve the questionnaire is
    an outage.
    """
    if os.environ.get("CHAT_PROXY_DISABLE") == "1":
        print("[entrypoint] chat proxy disabled by CHAT_PROXY_DISABLE=1", flush=True)
        return
    if not os.path.exists(script):
        print(f"[entrypoint] chat proxy not found at {script}; /api/chat will 502", flush=True)
        return

    child_env = dict(os.environ)
    # Loopback only: nginx is the sole client, and the proxy has no auth of
    # its own. The port is fixed here rather than read from the environment
    # because the nginx template hardcodes the matching upstream -- letting
    # them drift would be a silent 502.
    child_env["CHAT_PROXY_HOST"] = "127.0.0.1"
    child_env["CHAT_PROXY_PORT"] = CHAT_PROXY_PORT

    def run():
        backoff = CHAT_PROXY_MIN_BACKOFF
        while not _shutting_down.is_set():
            started = time.monotonic()
            try:
                proc = spawn([sys.executable, script], env=child_env)
            except OSError as exc:
                print(f"[entrypoint] could not start chat proxy: {exc}", flush=True)
                return
            code = proc.wait()
            if _shutting_down.is_set():
                return
            uptime = time.monotonic() - started
            print(
                f"[entrypoint] chat proxy exited (code {code}) after "
                f"{uptime:.0f}s; restarting in {backoff}s",
                flush=True,
            )
            # wait(), not sleep(), so a stop signal cuts the delay short
            # instead of holding shutdown open for up to a minute.
            _shutting_down.wait(backoff)
            # A proxy that stayed up is treated as healthy, so a one-off
            # crash months in does not inherit a minute-long penalty.
            backoff = (
                CHAT_PROXY_MIN_BACKOFF
                if uptime > CHAT_PROXY_MAX_BACKOFF
                else min(backoff * 2, CHAT_PROXY_MAX_BACKOFF)
            )

    # Daemon: nginx owns the container's lifetime, so this must not keep the
    # process alive on its own.
    threading.Thread(target=run, name="chat-proxy-supervisor", daemon=True).start()
    print(f"[entrypoint] chat proxy starting on 127.0.0.1:{CHAT_PROXY_PORT}", flush=True)


def main():
    base_url = sanitize_base_url(
        os.environ.get("ORDS_BASE_URL") or DEFAULT_ORDS_BASE_URL
    )
    # Env var wins, so rotating to a real secret later needs no code change.
    api_key = sanitize_api_key(
        os.environ.get("ORDS_API_KEY") or DEFAULT_ORDS_API_KEY
    )
    resolver = detect_resolver()

    with open(TEMPLATE, encoding="utf-8") as handle:
        config = handle.read()

    for token, value in (
        ("__RESOLVER__", resolver),
        ("__ORDS_BASE_URL__", base_url),
        ("__ORDS_API_KEY__", api_key),
    ):
        config = config.replace(token, value)

    left = re.findall(r"__[A-Z_]+__", config)
    if left:
        sys.exit(f"Unsubstituted tokens remain in the nginx config: {sorted(set(left))}")

    with open(OUTPUT, "w", encoding="utf-8") as handle:
        handle.write(config)

    # Deliberately never logs api_key.
    print(
        "[entrypoint] nginx resolver={} ords={}".format(
            resolver, base_url or "(unset -- /ords/ will return 503)"
        ),
        flush=True,
    )

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    supervise_chat_proxy()

    # nginx runs as a child rather than replacing this process, because
    # exec would destroy the supervisor thread along with it and the chat
    # proxy would never be restarted. `daemon off` keeps nginx in the
    # foreground of its own process so wait() means something.
    nginx = spawn(["nginx", "-g", "daemon off;"])
    code = nginx.wait()

    # nginx leaving is the container's cue to end, whether that was a stop
    # signal or a crash. Either way the proxy must not be left running.
    request_stop()
    reap_children()
    print(f"[entrypoint] nginx exited with {code}", flush=True)
    sys.exit(code)


if __name__ == "__main__":
    main()
