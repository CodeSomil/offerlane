# syntax=docker/dockerfile:1
# Production images for the cloud API (P2.9). Targets: api (default), worker, migrate; devissuer is local-only.
#   docker build --target api -t offerlane-api .     docker build --target worker -t offerlane-worker .
# Every target runs as the unprivileged `node` user, and the app files are owned by root, so the process can't change its own code.
FROM node:26.13.0-slim AS deps
WORKDIR /app
RUN npm install -g pnpm@11.28.9 --no-fund --no-audit --loglevel=error
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/api/package.json apps/api/
COPY libs/contract/package.json libs/contract/
RUN pnpm install --frozen-lockfile --prod --filter @offerlane/api... --reporter=silent

FROM node:26.13.0-slim AS runtime
ENV NODE_ENV=production HOST=0.0.0.0 PORT=8787
WORKDIR /app
COPY --from=deps /app ./
COPY apps/api/src apps/api/src
COPY apps/api/migrations apps/api/migrations
COPY libs/contract/src libs/contract/src
COPY libs/contract/openapi.json libs/contract/
USER node
# The api package dir, so `--import tsx` resolves from its node_modules.
WORKDIR /app/apps/api
# SHORTCUT: runs TypeScript through tsx (libs/contract exports .ts source); emit JS to dist once the contract builds.

# DEV ONLY: a local OIDC issuer for compose.dev.yml and scripts/load_test.sh. Never deploy it.
FROM runtime AS devissuer
COPY apps/api/test/fakeIssuer.ts apps/api/test/devIssuerApp.ts apps/api/test/devIssuer.ts /app/apps/api/test/
CMD ["node", "--import", "tsx", "test/devIssuer.ts"]

FROM runtime AS migrate
CMD ["node", "--import", "tsx", "src/db/migrate.ts", "up"]

FROM runtime AS worker
CMD ["node", "--import", "tsx", "src/worker.ts"]

FROM runtime AS api
EXPOSE 8787
CMD ["node", "--import", "tsx", "src/server.ts"]
