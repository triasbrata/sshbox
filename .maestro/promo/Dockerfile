# jeansh-demo:claude — the promo's SSH box with Claude Code in it.
# Build: sudo docker build -t jeansh-demo:claude - < .maestro/promo/Dockerfile
# The base is the image jeansh-demo first ran, pinned by digest.
FROM lscr.io/linuxserver/openssh-server:10.3_p1-r1-ls236@sha256:39ba37d50fdd6be1bf70644c871e5dcb9234ee79ac56424ea03ca08cadf1e7b0

# tmux and git were apk-added by hand in the old container; libgcc, libstdc++
# and ripgrep are what Claude Code's native build needs on Alpine (musl).
RUN apk add --no-cache tmux git libgcc libstdc++ ripgrep

# The login user's home is /config, a volume that hides anything built into
# it, so Claude is installed under /opt/claude and linked onto every PATH.
# The auto-updater is off because it would install a second copy into
# /config that PATH never reaches; rebuild the image to update instead.
RUN curl -fsSL https://claude.ai/install.sh | HOME=/opt/claude bash \
 && ln -s /opt/claude/.local/bin/claude /usr/local/bin/claude \
 && mkdir -p /etc/claude-code \
 && printf '{"env":{"DISABLE_AUTOUPDATER":"1","USE_BUILTIN_RIPGREP":"0"}}\n' \
      > /etc/claude-code/managed-settings.json
