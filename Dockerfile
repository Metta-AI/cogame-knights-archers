# Build Docker. ONE image, TWO entrypoints: /bin/knights-archers (the game
# server) and /bin/knights-archers-player (the thin seat registrar). The whole
# policy set is env-switched inside this same image (PLAYER_PROMPT vs
# PLAYER_SCRIPTED), which is what keeps a champion and a scripted filler
# byte-identical apart from their environment.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/knights-archers
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
RUN nim c \
  $NimFlags \
  --nimcache:/tmp/knights-archers-nimcache \
  --out:knights-archers \
  src/knights_archers.nim && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/knights-archers-player-nimcache \
  --out:knights-archers-player \
  src/knights_archers_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/knights-archers
COPY --from=build /workspace/knights-archers/knights-archers /bin/knights-archers
COPY --from=build /workspace/knights-archers/knights-archers-player \
  /bin/knights-archers-player
COPY --from=build /workspace/knights-archers/*.json ./
COPY --from=build /workspace/knights-archers/data ./data
COPY --from=build /workspace/knights-archers/client ./client

CMD ["/bin/knights-archers"]
