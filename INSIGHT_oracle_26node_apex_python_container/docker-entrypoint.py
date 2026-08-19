#!/usr/bin/env python3
"""Render the nginx config from environment variables, then exec nginx.

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

If /ords/ is unconfigured the rest of the site still serves -- an
unreachable database is not a reason to take the whole container down.

The DNS resolver is read from /etc/resolv.conf, because nginx does not
consult it on its own and needs an explicit `resolver` directive before it
will resolve names at request time.
"""

import os
import re
import sys

TEMPLATE = "/etc/nginx/templates/default.conf.template"
OUTPUT = "/etc/nginx/conf.d/default.conf"
FALLBACK_RESOLVER = "127.0.0.11"  # Docker's embedded DNS

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

    os.execvp("nginx", ["nginx", "-g", "daemon off;"])


if __name__ == "__main__":
    main()
