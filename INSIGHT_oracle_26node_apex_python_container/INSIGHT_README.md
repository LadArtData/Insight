# INSIGHT — 26-Node EDL Matrix

## Real environment: one login (ADMIN), data lives in ITERIA_AI
This targets an Oracle Autonomous Database workspace where **ADMIN is the
only login** and ORDS/APEX are already provisioned. Following the existing
convention in that workspace (FRP Studio's `FRP_DOCS`, `FRP_CHUNKS`, etc.
live in `ITERIA_AI`, while the ORDS REST modules that expose them --
`frp-hooks`, `scout-hooks`, `validate-hooks` -- are registered under
`ADMIN`), INSIGHT follows the same split:

- **Tables + package deploy into `ITERIA_AI`** (`INSIGHT_01`-`INSIGHT_05`).
  Each script leads with `ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;`,
  so just stay connected as ADMIN and run them in SQL Developer Web /
  Database Actions.
- **The ORDS REST module registers under `ADMIN`** (`INSIGHT_06`), same as
  the other three modules, and reaches into `ITERIA_AI` for every call.

Run in order, connected as ADMIN:

```
sql/INSIGHT_01_schema_a_nodes_26.sql              -- data-layer tables (-> ITERIA_AI)
sql/INSIGHT_02_schema_b_edl_rules.sql             -- EDL rules table + seed rules (-> ITERIA_AI)
sql/INSIGHT_03_pkg_insight_board_engine_spec.sql  -- pkg_insight_board_engine spec (-> ITERIA_AI)
sql/INSIGHT_04_pkg_insight_board_engine_body.sql  -- pkg_insight_board_engine body (-> ITERIA_AI)
sql/INSIGHT_05_seed_initial_data.sql              -- board 1 + its 26 nodes (-> ITERIA_AI)
sql/INSIGHT_06_ords_rest_module.sql               -- native ORDS REST module (-> ADMIN, calls into ITERIA_AI)
```

(`03`/`04` were renamed along with the package -- if you have the old
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

## Discovery questionnaire backend (INSIGHT_07-12)
`INSIGHT_app.html` (the client discovery questionnaire) originally only had
a `localStorage` fallback -- no real backend. `sql/INSIGHT_07`-`12` add one,
as a separate feature from the 26-node EDL matrix above; both deploy into
the same `ITERIA_AI` schema but don't interact with each other. Run in
order, connected as ADMIN:

```
sql/INSIGHT_07_questionnaire_schema.sql              -- insight_questions, insight_clients, insight_client_answers
sql/INSIGHT_08_questionnaire_answers_pkg.sql          -- insight_answer_change_requests + pkg_insight_answers spec
sql/INSIGHT_09_questionnaire_answers_pkg_body.sql     -- pkg_insight_answers body (edit-approval workflow)
sql/INSIGHT_10_questionnaire_documents.sql            -- insight_client_documents, insight_document_chunks (VECTOR)
sql/INSIGHT_11_questionnaire_client_sheet_view.sql    -- insight_client_sheet, insight_client_summary views
sql/INSIGHT_12_questionnaire_seed_questions.sql       -- MERGE-seeds the 91 real questions into insight_questions
```

Design decisions, in short:
- **Questions are metadata, not columns.** `insight_questions` drives what
  gets asked; adding a question later is a new row, not a schema change.
  `INSIGHT_12` seeds this table from the same `ALL_QUESTIONS` array the
  front end uses, generated programmatically so it can't drift from what
  the app actually asks -- re-generate it from that source if questions
  change, don't hand-edit the MERGE.
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
docker compose up -d
docker compose logs -f oracle-db   # first boot takes a few minutes
```

On first boot the container creates an `iteria_ai` app user and then runs
`sql/INSIGHT_01`-`05` (unmodified, via `docker/initdb/010_insight_schema.sql`)
against the `FREEPDB1` pluggable database. Once `docker compose ps` shows
`healthy`, connect as `iteria_ai` / `<APP_USER_PASSWORD>` at
`localhost:1521/FREEPDB1`. `sql/INSIGHT_06`, `ADMIN_reference_export.sql`,
and `INSIGHT_ADMIN_cleanup_old_objects.sql` are intentionally not run
automatically -- they're either ORDS-specific or one-off ADMIN helpers.

## Optional: bulk document ingestion
`python/INSIGHT_oracle_doc_ingestion.py` is a standalone script that walks a
local folder and writes each file's content into a node's `payload_json` in
`insight_nodes_26`, round-robining across nodes 1-26. Run it against either
the local Docker DB above or the real database once `INSIGHT_01`-`05` have
been applied:

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
utility, not a dependency of `INSIGHT_01`-`06` -- skip it if you don't need
bulk file ingestion.

## Local web UI (port 8000)
`docker compose up -d` also starts `insight-web`, a plain nginx container
serving `web/index.html` (a copy of the INSIGHT app UI) at
`http://localhost:8000`. It's the same clickable, localStorage-backed
front end you'd get opening the HTML file directly -- no backend, no live
data, just reachable over HTTP instead of `file://`. If you deploy this
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
- `sql/`: `INSIGHT_01`-`04` schema + package, `INSIGHT_05` seed data,
  `INSIGHT_06` native ORDS module -- all target ITERIA_AI except `06`
  (ADMIN, calls into ITERIA_AI). `INSIGHT_07`-`12` are the separate
  discovery-questionnaire backend (schema, approval workflow, documents,
  consolidated views, question seed data) -- see "Discovery questionnaire
  backend" above. `INSIGHT_ADMIN_cleanup_old_objects.sql` is a one-off
  helper, not part of either numbered sequence.
- `apex/`: static HTML + JS for the APEX page / standalone browser use.
- `python/`: standalone document-ingestion script (`INSIGHT_oracle_doc_ingestion.py`)
  + `INSIGHT_requirements.txt` -- run directly with python3 against either
  the local Docker DB or the real database. `Dockerfile` packages it as a
  container image, built/published by `.github/workflows/docker-publish.yml`.
- `docker/`: `docker-compose.yml` + `initdb/` for a local Oracle Database
  Free container (dev/test only -- no ORDS/APEX). See "Local Docker Oracle
  DB" above.
- `web/`: `index.html`, a copy of the app UI, served by the `insight-web`
  nginx service on port 8000. See "Local web UI" above.
