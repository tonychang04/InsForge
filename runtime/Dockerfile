# World runtime template: worldd over a mounted CoW workspace volume.
# The control plane injects the World's env bindings (DATABASE_URL, S3
# credentials, WORKSPACE_TOKEN, PORT) at machine create/clone time.
FROM node:22-slim

WORKDIR /opt/insforge
COPY worldd.mjs ./

VOLUME /workspace
ENV WORKSPACE_DIR=/workspace

EXPOSE 7400
CMD ["node", "worldd.mjs"]
