# FOUNDER OS — production image (Coolify / any Docker host).
# node:22-slim (Debian, glibc) rather than alpine for the final stages:
# better-sqlite3 ships prebuilt binaries for glibc, and building on musl
# would force a slower source compile every time the base image updates.

# ---- deps -------------------------------------------------------------------
# Full node:22 (not -slim) here on purpose: it already ships gcc/make/python3
# for the rare case npm has to compile better-sqlite3 from source instead of
# pulling its prebuilt binary, so this stage skips its own apt-get install.
# That apt step (python3 make g++, ~130s) was pushing total build time past
# Coolify's remote-command timeout on first deploy — see git history.
FROM node:22 AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

# ---- build --------------------------------------------------------------
FROM node:22-slim AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build
# Drop devDependencies (typescript, vitest, tailwind, …) now that the build
# output exists; only runtime deps ship in the final image.
RUN npm prune --omit=dev

# ---- runtime --------------------------------------------------------------
FROM node:22-slim AS runner
WORKDIR /app
ENV NODE_ENV=production
# Where the SQLite file lives — mount a volume here in production so
# data/founder-os.db survives redeploys. See lib/paths.ts.
ENV DATA_DIR=/app/data
# The start script always binds 4100 regardless of $PORT (see EXPOSE below),
# but instrumentation.ts reads $PORT for its own internal self-fetches
# (cron tick, failover tick, comms warmup), so it still needs to match.
ENV PORT=4100

RUN groupadd --system --gid 1001 nodejs \
    && useradd --system --uid 1001 --gid nodejs founderos \
    && mkdir -p /app/data \
    && chown -R founderos:nodejs /app/data

COPY --from=builder --chown=founderos:nodejs /app/public ./public
COPY --from=builder --chown=founderos:nodejs /app/.next ./.next
COPY --from=builder --chown=founderos:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=founderos:nodejs /app/package.json ./package.json
COPY --from=builder --chown=founderos:nodejs /app/next.config.mjs ./next.config.mjs

USER founderos

# Fixed port — the start script binds -p 4100 regardless of $PORT.
EXPOSE 4100

# Healthy = the HTTP server answers at all. A 401 from the access-gate
# middleware (FOUNDER_OS_ACCESS_TOKEN set) still counts as healthy; only a
# connection failure does not.
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=6 \
  CMD node -e "require('http').get('http://127.0.0.1:4100/',r=>process.exit(0)).on('error',()=>process.exit(1))"

# Invoke next directly rather than via "npm start" — npm wraps it in a child
# process and, as this non-root user, fails to write its own log on SIGTERM
# (harmless, but noisy on every restart); this way Docker's stop signal goes
# straight to the Next.js server.
CMD ["node_modules/.bin/next", "start", "-p", "4100"]
