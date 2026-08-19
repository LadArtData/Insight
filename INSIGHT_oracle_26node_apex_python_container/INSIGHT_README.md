# INSIGHT — 26-Node EDL Matrix

## Real environment: one login (ADMIN), data lives in ITERIA_AI
This targets an Oracle Autonomous Database workspace where **ADMIN is the
only login** and ORDS/APEX are already provisioned. Following the existing
convention in that workspace (FRP Studio's `FRP_DOCS`, `FRP_CHUNKS`, etc.
live in `ITERIA_AI`, while the ORDS REST modules that expose them --
`frp-hooks`, `scout-hooks`, `validate-hooks` -- are registered under
`ADMIN`), INSIGHT follows the same split:

- **Tables + package deploy into `ITERIA_AI`** (`V1`-`V5`). Each script
  leads with `ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;`, so connect
  as ADMIN and apply them via Flyway (see "Applying migrations" below) --
  running them by hand in SQL Developer Web / Database Actions still works
  too, in order, if you ever need to.
- **The ORDS REST module registers under `ADMIN`** (`INSIGHT_06`), same as
  the other three modules, and reaches into `ITERIA_AI` for every call.
  It's a one-off ORDS metadata registration against a real ORDS-enabled
  environment, not a schema migration -- it's intentionally **not**
  Flyway-tracked (doesn't match the `V<n>__...` naming Flyway scans for)
  and doesn't run against the local Docker container, which has no ORDS.
  Run it by hand, connected as ADMIN, once ORDS is available.

## Applying migrations (Flyway)
All schema changes (`sql/V1__...` through the current head) are applied
with [Flyway](https://flywaydb.org/) -- there's no dependency to install
locally, the official Docker image is enough:

```bash
docker run --rm -v "$(pwd)/sql:/flyway/sql:ro" flyway/flyway:11 \
  -url=jdbc:oracle:thin:@<host>:1521/<service> \
  -user=ADMIN -password=<password> \
  -locations=filesystem:/flyway/sql \
  -sqlMigrationPrefix=V -sqlMigrationSeparator=__ -sqlMigrationSuffixes=.sql \
  migrate
```

Against the local Docker container, `docker/docker-compose.yml` already
wraps this (see "Local Docker Oracle DB" below):
`docker compose --profile migrate run --rm flyway`.

**Adopting Flyway against an environment that already has `V1`-`V6` applied
by hand** (e.g. the real ADB, which was set up before Flyway existed here):
run `flyway baseline -baselineVersion=5` once first -- this tells Flyway
"V1-V5 are already done, don't try to re-run them," without touching the
database. (Baseline at 5, not 6, since V6 was never Flyway-tracked.) After
that, a normal `flyway migrate` applies anything newer.

`sql/INSIGHT_06_ords_rest_module.sql`, `sql/ADMIN_reference_export.sql`,
and `sql/INSIGHT_ADMIN_cleanup_old_objects.sql` are deliberately excluded
from every migrate run above (filename doesn't match `V<n>__...`) -- run
them by hand, connected as ADMIN, when their specific circumstance applies.

(`V3`/`V4` carry the package rename forward -- if you have the old
`INSIGHT_03_pkg_ai_board_engine_spec.sql` / `INSIGHT_04_pkg_ai_board_engine_body.sql`
saved anywhere, delete them and use these instead.)

Object names, all prefixed `INSIGHT_` (dropped the old bare `AI_` prefix so
they read consistently with `FRP_*`):

| Old name | New name |
|---|---|
| `AI_BOARDS` | `INSIGHT_BOARDS` |
| `AI_NODES_26` | `INSIGHT_NODES_26` |
| `AI_BOARD_ACTIVITY_LOG` | `INSIGHT_BOARD_ACTIVITY_LOG` |
| `AI_EDL_RULES` | `INSIGHT_EDL_RULES` |
| `PKG_AI_BOARD_ENGINE` | `PKG_INSIGHT_BOARD_ENGINE` |

Already ran `INSIGHT_01`/`02` once under ADMIN before this rename? Run
`sql/INSIGHT_ADMIN_cleanup_old_objects.sql` (connected as ADMIN) to drop
those orphaned `AI_*` copies -- it's safe to run even if some objects were
never created.

`INSIGHT_06` follows the exact `ORDS.DEFINE_MODULE` / `DEFINE_TEMPLATE` /
`DEFINE_HANDLER` pattern already used by `frp-hooks` (see `ADMIN.sql`):
`plsql/block` handlers, the same `iteria_ai.api_configuration` api_key
check, `:body_text` + `JSON_VALUE` for POST bodies, `APEX_JSON.STRINGIFY`
for output, `:status` for HTTP codes. Once run, it publishes:

```
GET  /ords/admin/insight-hooks/health
GET  /ords/admin/insight-hooks/matrix/{board_id}
POST /ords/admin/insight-hooks/nodes/{node_id}/trigger
```

Neither this module nor the APEX static files fabricate data -- every
response comes from a real call into `iteria_ai.pkg_insight_board_engine`.

## Wiring the APEX static files
`apex/INSIGHT_apex_ai_matrix_26.html` + `.js` render the 26-node grid.
Reference the JS from Shared Components > Static Application Files
(`#APP_FILES#INSIGHT_apex_ai_matrix_26.js`). Two call paths, both live:

- Inside APEX: `apex.server.process('HANDLE_EDL_EVENT' / 'GET_MATRIX_STATE', ...)`.
  These are Application Processes you create in Page Designer (Ajax
  Callback type) -- APEX metadata, not files -- that call
  `iteria_ai.pkg_insight_board_engine.process_edl_event` /
  `.get_matrix_state_json` and return the result.
- Outside APEX (e.g. opening the HTML file directly): the JS calls the
  native ORDS module above. Set `window.INSIGHT_CONFIG = { ordsBaseUrl,
  boardId, apiKey }` before the script loads if this file isn't served from
  the same origin as ORDS, or if `iteria_ai.api_configuration` has an
  active key.

## Discovery questionnaire backend (V7-V13)
`INSIGHT_app.html` (the client discovery questionnaire) has no real backend
wired up yet -- its `window.storage` fallback is in-memory only (per
browser tab, cleared on reload), not `localStorage`, deliberately: this is
real client discovery data with no auth/encryption/access control in front
of it yet, so nothing persists to disk until a secured backend exists.
`sql/V7`-`V13` build that backend's schema, as a separate feature from the
26-node EDL matrix above; both deploy into the same `ITERIA_AI` schema but
don't interact with each other. Applied the same way as V1-V5 -- see
"Applying migrations" above:

```
sql/V7__questionnaire_schema.sql               -- insight_questions, insight_clients, insight_client_answers
sql/V8__questionnaire_answers_pkg.sql          -- insight_answer_change_requests + pkg_insight_answers spec
sql/V9__questionnaire_answers_pkg_body.sql     -- pkg_insight_answers body (edit-approval workflow)
sql/V10__questionnaire_documents.sql           -- insight_client_documents, insight_document_chunks (VECTOR)
sql/V11__questionnaire_client_sheet_view.sql   -- insight_client_sheet, insight_client_summary views
sql/V12__questionnaire_seed_questions.sql      -- MERGE-seeds the 91 real questions into insight_questions
sql/V13__seed_locked_question_answers.sql      -- trigger: seeds locked-question answers (e.g. QUAL-GL) on client creation
```

Design decisions, in short:
- **Questions are metadata, not columns.** `insight_questions` drives what
  gets asked; adding a question later is a new row, not a schema change.
  `V12` seeds this table from the same `ALL_QUESTIONS` array the front end
  uses, generated programmatically so it can't drift from what the app
  actually asks -- re-generate it from that source if questions change,
  don't hand-edit the MERGE.
- **Answers are one row per (client, question)** in `insight_client_answers`,
  not a JSON blob per client, so they're queryable and support per-question
  approval.
- **Edits to an already-answered question go through approval.** The first
  answer for a question writes directly; changing it after that creates a
  row in `insight_answer_change_requests` instead of overwriting, until
  someone calls `pkg_insight_answers.approve_change_request`. Skips are
  exempt (marking "come back to this" isn't a data change worth gating).
  This is the governance workflow from the architecture notes -- it exists
  to catch a value getting quietly changed without a record of who/why.
- **Locked questions (e.g. `QUAL-GL`) get a real answer row automatically.**
  `V13`'s `trg_insight_clients_seed_locked` trigger inserts a `'Yes'` answer
  for every `is_locked = 1` question the moment a client is created.
  Without this, `insight_client_summary`'s scope-detection EXISTS check
  (which needs a real `QUAL-GL` row to include GL in the denominator) would
  never find one, and every GL question -- 18 of them required, out of 29
  required questions on a GL-only client -- would silently never count
  toward completion %. Verified directly: inserting a client with zero
  other answers gives `required_count = 29` immediately (11 phase-1/2 +
  18 GL), not 11.
- **Documents live in Object Storage, not the database.**
  `insight_client_documents` only stores a bucket/object pointer + status;
  `insight_document_chunks` holds chunked text and an Oracle 23ai native
  `VECTOR` embedding per chunk, so there's no separate vector database to
  run. No vector index is created yet -- add one (HNSW/IVF) once real
  volume/query patterns justify a specific choice.
- **"One sheet per client" is two views, not one.** `insight_client_sheet`
  is the full per-question detail for one client (long/tall format, so it
  absorbs new questions automatically instead of needing new columns).
  `insight_client_summary` is the one-row-per-client management rollup --
  progress %, pending-approval count, document count -- matching the
  three-tier access model in `INSIGHT_Implementation_Architecture_Notes.md`.
  Its scope-detection subquery casts `answer_value` (CLOB) to
  `VARCHAR2(10)` before comparing it -- Oracle rejects a bare CLOB used
  as a comparison key in this join shape (`ORA-22848`), caught by actually
  running this migration rather than by static review.

Row-level access control (which consultant sees which clients, and the
management-vs-consultant-vs-implementation-team split) isn't enforced yet --
these tables/views are the data layer; Oracle Virtual Private Database (VPD)
policies on `insight_clients` are the natural place to add that once the
access rules are actually specified.

## Local Docker Oracle DB (dev/test)
`docker/docker-compose.yml` runs a local Oracle Database Free container
(`gvenzl/oracle-free:23-slim`) as a stand-in for the real Autonomous DB when
you want to develop or test the schema/package/seed data without touching
the real environment. It does **not** include ORDS or APEX -- `sql/INSIGHT_06`
and the `apex/` static files still need the real ADB (or a separate ORDS
install) to run end-to-end.

```bash
cd docker
cp .env.example .env      # set ORACLE_PASSWORD and APP_USER_PASSWORD
docker compose up -d oracle-db
docker compose logs -f oracle-db          # first boot takes a couple minutes
docker compose --profile migrate run --rm flyway   # applies sql/V1-V13 (skips V6, see above)
```

Once `docker compose ps` shows `healthy`, connect as `iteria_ai` /
`<APP_USER_PASSWORD>` at `localhost:1521/FREEPDB1`. Schema is **not**
auto-applied on first boot (that was the old `docker/initdb/` wrapper,
removed in favor of Flyway being the one tracked way scripts get applied,
for this container and the real ADB alike) -- run the `flyway` command
above whenever you want the schema present, including after a fresh
`docker compose down -v`. `sql/INSIGHT_06`, `ADMIN_reference_export.sql`,
and `INSIGHT_ADMIN_cleanup_old_objects.sql` are intentionally not part of
that run -- they're either ORDS-specific or one-off ADMIN helpers.

## Optional: bulk document ingestion
`python/INSIGHT_oracle_doc_ingestion.py` is a standalone script that walks a
local folder and writes each file's content into a node's `payload_json` in
`insight_nodes_26`, round-robining across nodes 1-26. Run it against either
the local Docker DB above or the real database once `V1`-`V5` have been
applied:

```bash
pip install -r python/INSIGHT_requirements.txt
export ORACLE_HOST=<db>-<tenancy>.adb.<region>.oraclecloud.com
export ORACLE_SERVICE=<service_name_or_tns_alias>
export ORACLE_USER=iteria_ai
export ORACLE_PASS=<iteria_ai password>
python3 python/INSIGHT_oracle_doc_ingestion.py /path/to/docs
```

If the ADB requires mTLS, set `TNS_ADMIN` to the unzipped wallet directory
and use the wallet's TNS alias as `ORACLE_SERVICE`. This is a convenience
utility, not a dependency of `V1`-`V5` -- skip it if you don't need bulk
file ingestion.

## Local web UI (port 8000)
`docker compose up -d` also starts `insight-web`, a plain nginx container
serving `web/index.html` (a copy of the INSIGHT app UI) at
`http://localhost:8000`. It's the same clickable, in-memory-only front end
you'd get opening the HTML file directly -- no backend, no data persisted
anywhere, just reachable over HTTP instead of `file://`. If you deploy this
compose file to a cloud instance, port 8000 needs its own inbound rule in
that instance's Security List/NSG (separate from 1521's rule) or the page
won't load from outside. `web/index.html` is a plain copy, not a symlink --
if you edit the app UI, copy the updated file into `web/index.html` too.

## CI: publishing the ingestion image
`.github/workflows/build.yml` builds `python/Dockerfile` and pushes it to
OCIR on every push to `main`, matching the same pattern used in Validatev5:
`bom.ocir.io/bmi3vxyqnzrv/insight:amd64-insight`. It logs in with the repo
secrets `OCIR_USERNAME` / `OCIR_PASSWORD` -- these need to exist on this
repo (or be shared at the org level) or the login step will fail.
`.github/workflows/ci.yml` is separate and just validates the compose file
+ Python syntax on every push/PR.

## Directory structure
- `sql/`: `V1`-`V4` schema + package, `V5` seed data -- all Flyway-tracked,
  target ITERIA_AI. `V7`-`V13` are the separate discovery-questionnaire
  backend (schema, approval workflow, documents, consolidated views,
  question seed data, locked-answer trigger) -- see "Discovery
  questionnaire backend" above, also Flyway-tracked. `flyway.conf` holds
  the shared Flyway settings (see "Applying migrations" above).
  `INSIGHT_06_ords_rest_module.sql` (ADMIN, ORDS metadata),
  `ADMIN_reference_export.sql`, and `INSIGHT_ADMIN_cleanup_old_objects.sql`
  are intentionally **not** Flyway-tracked -- one-off/environment-specific,
  run by hand.
- `apex/`: static HTML + JS for the APEX page / standalone browser use.
- `python/`: standalone document-ingestion script (`INSIGHT_oracle_doc_ingestion.py`)
  + `INSIGHT_requirements.txt` -- run directly with python3 against either
  the local Docker DB or the real database. `Dockerfile` packages it as a
  container image, built/published by `.github/workflows/docker-publish.yml`.
- `docker/`: `docker-compose.yml` for a local Oracle Database Free
  container (dev/test only -- no ORDS/APEX) plus an opt-in `flyway`
  service (`--profile migrate`) that applies `sql/V*.sql` against it. See
  "Local Docker Oracle DB" above.
- `web/`: `index.html`, a copy of the app UI, served by the `insight-web`
  nginx service on port 8000. See "Local web UI" above.
