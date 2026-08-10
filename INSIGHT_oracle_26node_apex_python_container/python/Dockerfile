# Container image for the standalone ingestion script.
# Build context is the `python/` folder itself.
#
# Usage:
#   docker run --rm \
#     -e ORACLE_HOST=... -e ORACLE_PORT=1521 -e ORACLE_SERVICE=FREEPDB1 \
#     -e ORACLE_USER=iteria_ai -e ORACLE_PASS=... \
#     -v /path/to/docs:/docs:ro \
#     ghcr.io/<owner>/insight/insight-doc-ingestion:latest /docs
#
# For the real Autonomous DB (wallet/mTLS), also mount the wallet dir and
# set TNS_ADMIN:
#   -v /path/to/wallet:/wallet:ro -e TNS_ADMIN=/wallet -e ORACLE_SERVICE=<tns_alias>

FROM python:3.12-slim

WORKDIR /app

COPY INSIGHT_requirements.txt .
RUN pip install --no-cache-dir -r INSIGHT_requirements.txt

COPY INSIGHT_oracle_doc_ingestion.py .

ENTRYPOINT ["python", "INSIGHT_oracle_doc_ingestion.py"]
