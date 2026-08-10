FROM --platform=linux/amd64 python:3.11-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY INSIGHT_requirements.txt requirements.txt
RUN pip install --upgrade pip && pip install -r requirements.txt

COPY INSIGHT_oracle_doc_ingestion.py .

# Optional bulk ingest helper. Pass a docs path at runtime, e.g.:
#   docker run ... bom.ocir.io/.../insight:amd64-insight /docs
ENTRYPOINT ["python", "INSIGHT_oracle_doc_ingestion.py"]
