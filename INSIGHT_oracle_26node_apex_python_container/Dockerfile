# Combined single-container image for Insight: serves the web UI (nginx,
# main/foreground process, port 8000) and bundles the Python ingestion
# script + its dependencies for on-demand use via `docker exec`.
#
# Why one process runs in the foreground and the other doesn't: a container
# stays alive only as long as its main process does. nginx is a long-running
# server, so it's CMD. INSIGHT_oracle_doc_ingestion.py is a one-shot script
# (connects to Oracle, processes a folder, exits) -- if it were CMD instead,
# the container would exit right after it finished and nginx would never
# serve anything. Run it manually when needed:
#   docker exec -it <container> python /app/INSIGHT_oracle_doc_ingestion.py /docs
#
# Build context is this folder (INSIGHT_oracle_26node_apex_python_container)
# since it needs files from both python/ and web/.

FROM python:3.12-slim

# --- nginx, for serving web/index.html ---
RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx \
    && rm -rf /var/lib/apt/lists/*

COPY web/index.html /usr/share/nginx/html/index.html
COPY web/nginx.conf /etc/nginx/conf.d/default.conf

# --- ingestion script, for on-demand `docker exec` use ---
WORKDIR /app
COPY python/INSIGHT_requirements.txt .
RUN pip install --no-cache-dir -r INSIGHT_requirements.txt
COPY python/INSIGHT_oracle_doc_ingestion.py .

EXPOSE 8000
CMD ["nginx", "-g", "daemon off;"]
