# INSIGHT — 26-Node EDL Matrix

## Deployment model: one login (ADMIN), data lives in ITERIA_AI
This targets an Oracle Autonomous Database where **ADMIN is the only
login** and ORDS/APEX are already provisioned. Application objects are
kept out of `ADMIN` and owned by a dedicated schema, while the ORDS REST
module that exposes them is registered under `ADMIN` — the split is:

- **Tables + package deploy into `ITERIA_AI`** (`V1`-`V5`). Each script
  leads with `ALTER SESSION SET CURRENT_SCHEMA = ITERIA_AI;`, so connect
  as ADMIN and apply them via Flyway (see "Applying migrations" below) --
  running them by hand in SQL Developer Web / Database Actions still works
  too, in order, if you ever need to.
- **The ORDS REST module registers under `ADMIN`** (`INSIGHT_06`) and
  reaches into `ITERIA_AI` for every call.
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

`sql/INSIGHT_06_ords_module.sql` and
`sql/INSIGHT_ADMIN_cleanup_old_objects.sql` are deliberately excluded from
every migrate run above (their filenames don't match `V<n>__...`) -- run
them by hand, connected as ADMIN, when their specific circumstance applies.

(`V3`/`V4` carry the package rename forward -- if you have the old
`INSIGHT_03_pkg_ai_board_engine_spec.sql` / `INSIGHT_04_pkg_ai_board_engine_body.sql`
saved anywhere, delete them and use these instead.)

Object names are all prefixed `INSIGHT_` (replacing an earlier bare `AI_`
prefix, which was too generic to be safe in a shared schema):

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

`INSIGHT_06` defines a single ORDS module, `insight`, covering everything
the product exposes over REST — both the matrix and the questionnaire —
under one base path. It uses the standard `ORDS.DEFINE_MODULE` /
`DEFINE_TEMPLATE` / `DEFINE_HANDLER` pattern: `plsql/block` handlers, an
api_key check against `iteria_ai.insight_api_config` (`V14`), `:body_text`
+ `JSON_VALUE` for POST bodies, and `:status` for HTTP codes.

The key table is INSIGHT's own. An earlier revision read a table named
`API_CONFIGURATION` that INSIGHT does not own and no migration here
creates -- it belongs to something else sharing the schema. Every endpoint
therefore depended on another product's object being present, and when it
was not, the handlers died with `ORDS-25001` / HTTP 555. The lookup also
uses dynamic SQL now, so a missing key table degrades to "no key required"
instead of taking the API down: a static reference to an absent table is a
compile error, which the handler's own EXCEPTION clause cannot catch.

No active row in `insight_api_config` means no key is required.

```
GET  /ords/admin/insight/health
GET  /ords/admin/insight/matrix/{board_id}
POST /ords/admin/insight/nodes/{node_id}/trigger
```

An earlier revision split this across two modules, `insight-hooks` and
`insight-questionnaire`. That put one product behind two base paths and
two ORDS catalog entries for no benefit. `INSIGHT_06` drops both if it
finds them, so running it on a database that has them is the migration —
no manual cleanup required, and re-running it is safe.

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
  the same origin as ORDS, or if `iteria_ai.insight_api_config` has an
  active key.

## REST layer for the questionnaire
The same `insight` module publishes the questionnaire tables:

```
GET    /ords/admin/insight/clients
GET    /ords/admin/insight/clients/:client_id
PUT    /ords/admin/insight/clients/:client_id
DELETE /ords/admin/insight/clients/:client_id
GET    /ords/admin/insight/clients/:client_id/notes
POST   /ords/admin/insight/clients/:client_id/notes
PUT    /ords/admin/insight/clients/:client_id/notes
GET    /ords/admin/insight/clients/:client_id/updates
POST   /ords/admin/insight/clients/:client_id/updates
```

`GET clients/:client_id` reassembles the normalized rows into the exact
record shape the front end already uses — `{id, companyName,
primaryContact, answers, skipped, unknown, notes, createdAt, updatedAt}` —
so wiring the app to it needs no change to its save/load call sites.

An edit to an answer **that has a value** routes through the approval
workflow rather than overwriting. Filling a blank does not: a question that
was skipped or marked "not known yet" has a row but no value, so the first
real answer to it is ordinary intake and applies directly. Before `V21` the
gate keyed off the row rather than the value, which meant every answer given
in the AI Follow-Up chat -- whose entire job is filling gaps -- went to the
approval queue and never reached the record.

`PUT` upserts the client, its profile and its answers. Which fields it
touches is decided by **which keys are present**, not by their values: a
body carrying only `companyName`/`primaryContact` edits the profile and
leaves every answer alone, and one carrying only `answers` leaves the
profile alone. That distinction is what lets the client information sheet
rename a company without replaying the answer set — which would compare
all hundred of them and raise a change request for any that had drifted.
Sending `""` is a deliberate clear; omitting the key is not. The front end saves the entire
answer set on every save, while `pkg_insight_answers.record_answer` routes
any change to an already-answered question through the approval workflow.
Replaying every answer would therefore raise a PENDING change request per
question on every save, so the handler compares each answer against what
is stored and calls `record_answer` only where the value actually changed.
The response reports what happened:

```json
{"ok":true,"saved":3,"pendingApproval":1,"unknownQuestions":0}
```

`DELETE` archives (`status = 'ARCHIVED'`) rather than deleting, so answer
history survives. `GET clients` lists only ACTIVE rows.

The `notes` endpoints hold **additional information**: anything a client
says that no question asked. They are deliberately not answers — no
question id, no type, no option list, and no approval workflow, because
notes are appended rather than overwritten and appending destroys nothing.
Each carries the same `source` vocabulary as an answer (`SALES_INTAKE`,
`AI_ASSIST`, `CONSULTANT`), so a note the assistant proposed is
distinguishable from one a consultant typed. `PUT` takes `noteId` in the
body and edits or archives that note; archiving keeps the row, matching how
`DELETE` on a client keeps its answers. Requires `V20`.

The `updates` endpoints hold **configuration updates**: one row per time a
client's configuration was regenerated, and why. Append-only -- there is no
PUT, because an update is a record of something that happened. This is
distinct from `insight_answer_change_requests`, which is one proposed edit to
one answer awaiting approval; a configuration update is the business event
those edits sat underneath. Without it, a configuration handed over in March
and another in September differ for no recorded reason. Requires `V22`.

### How the front end selects its store
At startup the app probes `GET /clients` once and picks a backing store for
`window.storage` based on the result. Every call site goes through that one
interface, so nothing else in the app changes between modes:

| Probe result | Store | Records screen says |
|---|---|---|
| Returns JSON | ORDS | "Saved to the Insight database…" |
| Fails, blocked, or not JSON | In-memory | "Not connected to the records database…" |

Falling back rather than failing means a container without `ORDS_BASE_URL`,
or one pointed at a database where this module has not been installed,
still runs the questionnaire instead of showing an error. The fallback is
deliberately not `localStorage`: these are real client answers and there is
still no authentication, so a failed probe must not quietly start writing
them to disk in a browser profile.

Override the base path with `window.INSIGHT_API_BASE` if the app is served
somewhere that reaches ORDS on a different path.

Verify after installing:

```bash
curl -s "$ORDS/insight/clients"
curl -s -X PUT "$ORDS/insight/clients/test-001" \
  -H 'Content-Type: application/json' \
  -d '{"companyName":"Test Co","answers":{"INTAKE-001":"Test Co"},"skipped":{}}'
curl -s "$ORDS/insight/clients/test-001"
curl -s -X PUT "$ORDS/insight/clients/test-001" \
  -H 'Content-Type: application/json' \
  -d '{"primaryContact":"R. Alvarez"}'          # profile only; answers untouched
curl -s -X POST "$ORDS/insight/clients/test-001/notes" \
  -H 'Content-Type: application/json' \
  -d '{"text":"Board meets quarterly."}'
```

## Running the matrix without APEX
APEX is not required. The combined container image serves the same two
files and proxies the REST calls, so the matrix runs entirely from the
container:

- Questionnaire: `http://<host>:8000/`
- 26-node matrix: `http://<host>:8000/matrix.html`

The image copies `apex/INSIGHT_apex_ai_matrix_26.{html,js}` verbatim —
there is no container-specific variant to keep in sync. The page's
`INSIGHT_CONFIG` block is commented out, and the script falls back to
same-origin `/ords/admin/insight` whenever `apex.server` is absent,
which is exactly what the container's nginx proxies.

Configure the proxy with two environment variables:

| Variable | Required | Value |
|---|---|---|
| `ORDS_BASE_URL` | to reach ORDS | `scheme://host` of the ORDS server, **no path**, e.g. `https://abc-insight.adb.us-ashburn-1.oraclecloudapps.com` |
| `ORDS_API_KEY` | only if a key is active | Matching value from `iteria_ai.insight_api_config` |

```bash
docker run -p 8000:8000 \
  -e ORDS_BASE_URL=https://<db>-<name>.adb.<region>.oraclecloudapps.com \
  -e ORDS_API_KEY=<key> \
  bom.ocir.io/bmi3vxyqnzrv/insight-app:latest
```

Both are optional. With neither set the site still serves and `/ords/`
returns a 503 explaining that it is unconfigured — an unreachable database
is not a reason to take the whole container down.

The api_key is attached by nginx, server-side. The REST module accepts it
as a query parameter, so a browser-held key would otherwise be readable in
page source, the network tab, and every access log along the way. The
front end sends no key at all; access logging is disabled on `/ords/` so
this container doesn't record it either.

What APEX still provides that the container does not is authentication.
Nothing in the container path authenticates anyone — see the status note
in the top-level README.

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
sql/V14__insight_api_config.sql                -- insight_api_config: the api_key the ORDS handlers check
sql/V15__widen_answer_types.sql                -- answer_type widened for the typed questions
sql/V16__answer_provenance.sql                 -- answer_source, is_confirmed, is_unknown on insight_client_answers
sql/V17-V18__record_answer_provenance*.sql     -- record_answer gains p_source/p_is_unknown; adds confirm_answer
sql/V19__summary_counts_unknown.sql            -- insight_client_summary: "not known yet" counts as answered
sql/V20__client_profile_and_notes.sql          -- insight_client_notes: additional information, kept apart from answers
sql/V21__fill_blank_answers_without_approval.sql -- filling a blank is not an edit; repairs the answers that gated
sql/V22__configuration_updates.sql             -- insight_config_updates: why a configuration was regenerated
sql/V23__question_update_scope.sql             -- insight_questions.ask_on_update
sql/V24__questionnaire_seed_questions.sql      -- re-seeds the questions, now carrying ask_on_update
```

### Intake and update are different runs
`ask_on_update` marks which questions are asked again when a client is
updated. Intake collects everything needed to produce a configuration; an
update happens later, when something has changed and a new configuration is
needed. Walking someone back through the whole deck to change one thing is
how a tool stops being used.

The test is not "could this ever change" but "would changing this be an
update, or a re-implementation?" A ledger's currency, the chart of accounts
structure and the accounting calendar are decided once. How many years of
history to convert is meaningless a second time, because the conversion
already happened. Eighteen questions are marked `0`; the other eighty-two
are asked again.

Not asking is the lossy direction, so the column defaults to `1` and the
doubtful cases are `1` too — a consultant can skip a question they do not
need, but cannot answer one they are never shown. `0` does not mean frozen
either: every answer stays editable on the client information screen.

**The seed is regenerated into a new migration each time, never edited in
place.** Flyway checksums an applied migration, so editing `V12` after it has
run anywhere makes `flyway migrate` fail validation everywhere it has run.
`V12` is frozen history; `scripts/gen-sql-seed.js` writes the version named
in its `SEED_MIGRATION` constant, which is what moves.

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
`docker compose down -v`. `sql/INSIGHT_06` and
`INSIGHT_ADMIN_cleanup_old_objects.sql` are intentionally not part of that
run -- they're either ORDS-specific or one-off ADMIN helpers.

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

## Guidance panel
`questions/insight_question_guidance.json` holds per-question coaching for
whoever is running the intake: what Oracle setup the answer feeds, why the
question is asked, what a usable answer contains, what to ask when the first
answer is too vague, and a worked example. It is generated into the page by
`scripts/gen-js-questions.js` alongside `ALL_QUESTIONS`, so the app stays a
single self-contained file that still works opened off disk.

Reference material first, model second. Someone running their first intake
needs to know what a question means far more often than they need something
generated, and reference data has no latency and cannot be unavailable. The
"Ask the assistant" box underneath is for the question the reference did not
answer; it calls `/api/explain`, and when that is unreachable it says so
while everything above it keeps working.

The guidance is a **draft pending subject-matter review**, and deliberately
covers only Client Intake, the qualifiers and General Ledger — the areas the
OCWI configuration workbook grounds. AP, AR, Fixed Assets and Cash Management
have no entries rather than invented ones: plausible-sounding Fusion advice
is precisely what a first-timer has no way to evaluate. A question with no
guidance hides the panel instead of showing an empty box.

## AI assistant endpoint (`/api/chat`)
The combined image runs a second process alongside nginx:
`python/INSIGHT_chat_proxy.py`, a small service in front of OCI Generative
AI. It binds `127.0.0.1:5001` and is reachable only through nginx's
`/api/chat` location — the browser never holds OCI credentials, the same
reason the ORDS `api_key` is attached server-side.

The entrypoint supervises it: if it exits it is restarted with backoff, and
if it cannot start at all the site still serves and `/api/chat` returns
502. Set `CHAT_PROXY_DISABLE=1` to skip it entirely.

Three routes share it: `/chat` (gap follow-up), `/review` (is this answer
usable) and `/explain` (coach the consultant). Their nginx timeouts differ
by who is waiting — 8s for review, since a person is held at the Next
button; 60s for explain, where they asked and are reading; 240s for chat.

Authentication is chosen at startup (`OCI_AUTH_METHOD`, default `auto`):
a `~/.oci/config` when one exists, otherwise **instance principals**, which
is what the Container Instance uses since it has no config file to mount.
That requires two things in OCI, neither of which lives in this repo:

1. A dynamic group matching the Container Instance, e.g.
   `ALL {resource.type='computecontainerinstance', resource.compartment.id='<ocid>'}`
2. A policy granting it access:
   `allow dynamic-group <name> to use generative-ai-family in tenancy`

Without them the proxy starts, `/health` passes, and `/chat` returns 502 —
check the container log for the `[chat-proxy] OCI auth:` line to see which
method it chose.

Under `docker compose` the proxy runs as its own container instead
(`python/Dockerfile.chat-proxy`, which sets `CHAT_PROXY_HOST=0.0.0.0` so the
nginx container can reach it) with the host's `~/.oci` mounted read-only.

## CI: publishing images
`.github/workflows/build.yml` builds and pushes to OCIR. It has three
targets, selectable on a manual run (Actions → Run workflow):

| Target | Builds | Pushes |
|---|---|---|
| `combined` (default) | root `Dockerfile` | `insight-app:latest` |
| `web` | `web/Dockerfile` | `insight-web:latest` |
| `python` | `python/Dockerfile` | `insight:amd64-insight` |

A push to `main` builds `combined`, because that is the image deployed to
the Container Instance. The path filter covers everything baked into it:
`web/`, `python/`, and the root `Dockerfile`. Editing only SQL or APEX
files does not trigger an image build — those deploy to the database, not
the container.

Login uses the repo secrets `OCIR_USERNAME` / `OCIR_PASSWORD`; the
registry host and tenancy namespace are set in the workflow itself. Both
secrets must exist on the repo (or be inherited from the organization) or
the login step fails.

> A new image does **not** update a running OCI Container Instance. OCI
> does not re-pull a moving `:latest` tag, and instances are immutable
> after creation — deploying a new build means recreating the instance,
> which assigns a new public IP.

`.github/workflows/ci.yml` is separate: it runs the front-end regression
suite, verifies the two copies of the app HTML are in sync, checks the
generated question set matches `questions/insight_questions.json`,
compile-checks the Python, and validates the compose file.

## Directory structure
- `sql/`: `V1`-`V4` schema + package, `V5` seed data -- all Flyway-tracked,
  target ITERIA_AI. `V7`-`V20` are the separate discovery-questionnaire
  backend (schema, approval workflow, documents, consolidated views,
  question seed data, locked-answer trigger, answer provenance, client
  notes, the blank-fill fix, and configuration updates) -- see "Discovery
  questionnaire backend"
  above, also Flyway-tracked. `flyway.conf` holds
  the shared Flyway settings (see "Applying migrations" above).
  `INSIGHT_06_ords_module.sql` (ADMIN, ORDS metadata),
  `INSIGHT_ADMIN_cleanup_old_objects.sql` and
  `INSIGHT_ADMIN_reset_client_answers.sql` are intentionally **not**
  Flyway-tracked -- one-off/environment-specific, run by hand. The reset
  script in particular destroys data on purpose, which is the opposite of
  something every environment should run once without being asked.
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
