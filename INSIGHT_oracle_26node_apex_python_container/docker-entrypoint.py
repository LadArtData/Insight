#!/usr/bin/env python3
"""Render the nginx config from environment variables, then exec nginx.

Written in Python rather than shell because the combined image is based on
python:3.12-slim: the interpreter is already present, so this needs no
extra package (envsubst would mean pulling in gettext-base).

Environment:
  ORDS_BASE_URL   scheme://host of the ORDS server, no trailing path.
                  Example: https://abc123-insight.adb.us-ashburn-1.oraclecloudapps.com
                  If unset, /ords/ returns 503 and the rest of the site
                  still serves -- an unconfigured ORDS is not a reason to
                  take the whole container down.
  ORDS_API_KEY    api_key for the insight-hooks module. Optional; only
                  needed if iteria_ai.api_configuration holds an active key.

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
    """Reject anything that isn't a bare scheme://host.

    The value lands inside an nginx directive, so a stray quote or newline
    would corrupt the config -- and a trailing path would silently produce
    a doubled URI, since proxy_pass appends $uri.
    """
    value = (raw or "").strip().rstrip("/")
    if not value:
        return ""
    if not re.match(r"^https?://[A-Za-z0-9.\-]+(:\d+)?$", value):
        sys.exit(
            "ORDS_BASE_URL must be scheme://host[:port] with no path, got: "
            f"{value!r}"
        )
    return value


def sanitize_api_key(raw):
    value = (raw or "").strip()
    if value and not re.match(r"^[A-Za-z0-9._\-]+$", value):
        sys.exit("ORDS_API_KEY contains characters that are not safe in a URL.")
    return value


def main():
    base_url = sanitize_base_url(os.environ.get("ORDS_BASE_URL"))
    api_key = sanitize_api_key(os.environ.get("ORDS_API_KEY"))
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
