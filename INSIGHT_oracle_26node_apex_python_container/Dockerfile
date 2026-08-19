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

# --- web root: questionnaire at /, 26-node matrix at /matrix.html ---
COPY web/index.html /usr/share/nginx/html/index.html
# The matrix page and its script are copied verbatim from apex/ -- the same
# files uploaded to APEX Static Application Files. No container-specific
# variant exists, so the two deployments cannot drift: the page's
# INSIGHT_CONFIG block is commented out, and the script falls back to
# same-origin /ords/admin/insight whenever apex.server is absent,
# which is precisely what the proxy below serves.
COPY apex/INSIGHT_apex_ai_matrix_26.html /usr/share/nginx/html/matrix.html
COPY apex/INSIGHT_apex_ai_matrix_26.js /usr/share/nginx/html/INSIGHT_apex_ai_matrix_26.js

# nginx config is rendered at startup by docker-entrypoint.py, since the
# ORDS host and api_key are environment-specific and must not be baked in.
# Note this is NOT web/nginx.conf: that file proxies /api/chat to a host
# named "chat-proxy" which only exists inside docker-compose, and nginx
# resolves upstream hostnames at parse time, so it would kill this
# container with [emerg] host not found in upstream "chat-proxy".
COPY web/nginx.combined.conf.template /etc/nginx/templates/default.conf.template
COPY docker-entrypoint.py /usr/local/bin/docker-entrypoint.py

# --- ingestion script, for on-demand `docker exec` use ---
WORKDIR /app
COPY python/INSIGHT_requirements.txt .
RUN pip install --no-cache-dir -r INSIGHT_requirements.txt
COPY python/INSIGHT_oracle_doc_ingestion.py .

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/', timeout=2)" || exit 1

ENTRYPOINT ["python", "/usr/local/bin/docker-entrypoint.py"]
