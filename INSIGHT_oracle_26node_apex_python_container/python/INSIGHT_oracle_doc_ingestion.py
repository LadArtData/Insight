#!/usr/bin/env python3
"""
INSIGHT_oracle_doc_ingestion.py

Standalone bulk document ingestion utility for the INSIGHT 26-node EDL
matrix. Walks a local folder, reads each file's content, and round-robins
it into `insight_nodes_26.payload_json` (nodes 1-26) for a given board.

This is a convenience script, not a dependency of sql/INSIGHT_01-06. Run it
directly against a live database (local Docker container or the real
Oracle Autonomous Database) once INSIGHT_01-05 have been applied:

    pip install -r python/INSIGHT_requirements.txt
    export ORACLE_HOST=<db>-<tenancy>.adb.<region>.oraclecloud.com
    export ORACLE_SERVICE=<service_name_or_tns_alias>
    export ORACLE_USER=iteria_ai
    export ORACLE_PASS=<iteria_ai password>
    python3 python/INSIGHT_oracle_doc_ingestion.py /path/to/docs

Against the local Docker Oracle DB (see docker/docker-compose.yml):

    export ORACLE_HOST=localhost
    export ORACLE_PORT=1521
    export ORACLE_SERVICE=FREEPDB1
    export ORACLE_USER=iteria_ai
    export ORACLE_PASS=<same password used in docker/.env>
    python3 python/INSIGHT_oracle_doc_ingestion.py /path/to/docs

If the ADB requires mTLS, set TNS_ADMIN to the unzipped wallet directory and
use the wallet's TNS alias as ORACLE_SERVICE -- ORACLE_HOST/ORACLE_PORT are
ignored in that case.
"""

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import oracledb
except ImportError:
    sys.exit(
        "Missing dependency 'oracledb'. Install with:\n"
        "    pip install -r python/INSIGHT_requirements.txt"
    )

TOTAL_NODES = 26
DEFAULT_BOARD_ID = 1

# Files larger than this are truncated before being stored in payload_json
# (payload_json is a CLOB, but we still don't want to blow up memory/network
# on huge binary files that were never meant to be ingested as text).
MAX_BYTES = 200_000

# Extensions we treat as text and attempt to decode; anything else is
# skipped with a warning rather than silently corrupting payload_json.
TEXT_EXTENSIONS = {
    ".txt", ".md", ".json", ".csv", ".tsv", ".sql", ".py", ".js", ".html",
    ".htm", ".css", ".xml", ".yaml", ".yml", ".log", ".ini", ".cfg",
}


def env(name, default=None, required=False):
    val = os.environ.get(name, default)
    if required and not val:
        sys.exit(f"Missing required environment variable: {name}")
    return val


def get_connection():
    """
    Two supported connection modes:
      1. TNS_ADMIN set (wallet dir) -> connect using the wallet's TNS alias
         as ORACLE_SERVICE (mTLS, used for the real Autonomous DB).
      2. Plain host/port/service -> used for the local Docker Oracle DB, or
         any non-wallet Oracle instance.
    """
    user = env("ORACLE_USER", required=True)
    password = env("ORACLE_PASS", required=True)
    service = env("ORACLE_SERVICE", required=True)

    tns_admin = os.environ.get("TNS_ADMIN")
    if tns_admin:
        wallet_password = os.environ.get("ORACLE_WALLET_PASSWORD")
        return oracledb.connect(
            user=user,
            password=password,
            dsn=service,
            config_dir=tns_admin,
            wallet_location=tns_admin,
            wallet_password=wallet_password,
        )

    host = env("ORACLE_HOST", required=True)
    port = int(env("ORACLE_PORT", "1521"))
    dsn = oracledb.makedsn(host, port, service_name=service)
    return oracledb.connect(user=user, password=password, dsn=dsn)


def iter_files(root: Path):
    for path in sorted(root.rglob("*")):
        if path.is_file():
            yield path


def read_text(path: Path):
    if path.suffix.lower() not in TEXT_EXTENSIONS:
        return None
    try:
        data = path.read_bytes()
    except OSError as exc:
        print(f"  ! skip (read error): {path} ({exc})")
        return None
    truncated = len(data) > MAX_BYTES
    if truncated:
        data = data[:MAX_BYTES]
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        text = data.decode("utf-8", errors="replace")
    if truncated:
        text += "\n\n[...truncated: file exceeds {} bytes...]".format(MAX_BYTES)
    return text


def build_payload(path: Path, root: Path, text: str):
    return json.dumps(
        {
            "source_file": str(path.relative_to(root)),
            "ingested_at": datetime.now(timezone.utc).isoformat(),
            "size_bytes": len(text.encode("utf-8")),
            "content": text,
        }
    )


def main():
    if len(sys.argv) != 2:
        sys.exit(f"Usage: {sys.argv[0]} /path/to/docs")

    root = Path(sys.argv[1]).expanduser().resolve()
    if not root.is_dir():
        sys.exit(f"Not a directory: {root}")

    board_id = int(env("ORACLE_BOARD_ID", str(DEFAULT_BOARD_ID)))

    files = [p for p in iter_files(root)]
    if not files:
        print(f"No files found under {root}. Nothing to do.")
        return

    print(f"Found {len(files)} file(s) under {root}. Connecting to Oracle...")
    conn = get_connection()
    try:
        cur = conn.cursor()
        # Fail fast (and clearly) if INSIGHT_01/05 haven't been applied yet.
        cur.execute(
            "SELECT COUNT(*) FROM insight_nodes_26 WHERE board_id = :board_id",
            board_id=board_id,
        )
        (node_count,) = cur.fetchone()
        if node_count == 0:
            sys.exit(
                f"No rows in insight_nodes_26 for board_id={board_id}. "
                "Run sql/INSIGHT_01-05 first (INSIGHT_05 seeds board 1's 26 nodes)."
            )

        node_id = 1
        ingested = 0
        skipped = 0
        for path in files:
            text = read_text(path)
            if text is None:
                print(f"  - skip (unsupported/binary): {path.relative_to(root)}")
                skipped += 1
                continue

            payload = build_payload(path, root, text)
            cur.execute(
                """
                UPDATE insight_nodes_26
                   SET payload_json = :payload,
                       processing_count = processing_count + 1,
                       last_event_timestamp = SYSTIMESTAMP
                 WHERE board_id = :board_id
                   AND node_id = :node_id
                """,
                payload=payload,
                board_id=board_id,
                node_id=node_id,
            )
            print(f"  + node {node_id:2d}: {path.relative_to(root)}")
            ingested += 1
            node_id = node_id + 1 if node_id < TOTAL_NODES else 1

        conn.commit()
        print(f"\nDone. Ingested {ingested} file(s), skipped {skipped}.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
