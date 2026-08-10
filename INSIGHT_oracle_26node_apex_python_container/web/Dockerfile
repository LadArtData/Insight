# Self-contained image for the Insight web UI -- unlike docker-compose's
# insight-web service (which bind-mounts ../web from the host), this bakes
# index.html into the image so it can run standalone, e.g. as a container
# on an OCI Container Instance, where there's no host filesystem to mount
# from. Listens on 8000 directly (see nginx.conf) so it can be added to a
# Container Instance without needing a separate port-remap step.
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 8000
