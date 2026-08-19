# INSIGHT

INSIGHT supports Oracle Fusion Financials implementations. It captures a
client's requirements through a structured discovery questionnaire, stores
the answers in Oracle Autonomous Database, and turns them into the
configuration decisions an implementation needs.

It ships as three deliverables, each independently deployable:

| Deliverable | What it is | Where it runs |
|---|---|---|
| **Database** | Schema, PL/SQL packages and an ORDS REST module | Oracle Autonomous Database |
| **APEX** | Static page assets for the 26-node EDL matrix | APEX Static Application Files |
| **Container** | Questionnaire at `/`, matrix at `/matrix.html`, plus a bundled document-ingestion utility | Any container host (built and published to OCIR by CI) |

APEX is optional: the container serves the same matrix page and proxies
its REST calls to ORDS, so both features can run from the container alone.
What APEX provides that the container does not is authentication.

Nothing here depends on a developer workstation: the database objects are
applied by Flyway, the APEX assets are uploaded to APEX, and the container
image is built by CI with everything it serves baked in.

## Repository layout

```
.github/workflows/          CI and image build/publish pipelines
INSIGHT_app.html            Discovery questionnaire (source of truth)
INSIGHT_addons/             Chart-of-accounts setup tools and the
                            discovery/product-mapping workbook
INSIGHT_oracle_26node_apex_python_container/
  sql/                      Flyway migrations (V1..V13) + the ORDS module
  apex/                     APEX static files for the 26-node matrix
  web/                      Container web root, nginx configs, test suite
  python/                   Document ingestion + AI chat proxy services
  questions/                insight_questions.json — the question set
  scripts/                  Generators that keep the question set in sync
  docker/                   Local development stack (Oracle Free + web)
  Dockerfile                Combined image: web app + ingestion utility
```

Detailed deployment instructions live in
[`INSIGHT_oracle_26node_apex_python_container/INSIGHT_README.md`](INSIGHT_oracle_26node_apex_python_container/INSIGHT_README.md).

## The two features

**26-node EDL matrix** — `V1`–`V5` plus `INSIGHT_06`, surfaced through the
APEX page and the `insight-hooks` ORDS module. Event-driven logic runs in
`pkg_insight_board_engine` inside the database; no application server sits
in front of it.

**Discovery questionnaire** — `V7`–`V13`, a 91-question deck across three
phases: client intake, module scoping, then module-specific discovery.
Only modules the client actually needs are asked about. Questions are
metadata rows rather than columns, so adding one is an insert, not a
schema change. Answers are stored one row per question, and edits to an
already-answered question route through an approval workflow instead of
overwriting silently.

The two features share a schema but are otherwise independent.

## Single source of truth for the question set

`questions/insight_questions.json` defines the 91 questions. Two generators
derive from it — the `ALL_QUESTIONS` array in the app, and the SQL seed
migration. CI fails if either drifts from the JSON, so the deck cannot
diverge between the front end and the database.

## Getting started

Requirements: an Oracle Autonomous Database with ORDS and APEX
provisioned, Docker, and Node.js 22 for the test suite.

1. Apply the database migrations with Flyway (see `sql/flyway.conf`), then
   run `sql/INSIGHT_06_ords_rest_module.sql` as ADMIN to register the REST
   endpoints.
2. Upload `apex/` to APEX Static Application Files.
3. Run the container, or bring up the local stack with
   `docker compose up -d` from `docker/`.

To open the questionnaire without any backend, `INSIGHT_app.html` runs
standalone in a browser — answers are held in memory for that session
only.

## Development

```bash
cd INSIGHT_oracle_26node_apex_python_container/web
npm ci && npm test      # front-end regression suite
```

CI additionally verifies that `INSIGHT_app.html` and `web/index.html`
remain identical, that the generated question set matches the JSON, and
that the Python services compile and pass their unit tests.

## Status

The questionnaire front end and the database schema are built and tested.
The application is **not production-ready**: it has no authentication, no
TLS, and the front end is not yet wired to the database — answers do not
persist beyond a browser session. Those are the next milestones.

## License

Proprietary. See [LICENSE](LICENSE). Public visibility of this repository
does not grant permission to use its contents.
