#!/bin/bash
# Healthcheck silencioso do Servidor Terraria (tModLoader)
# Verifica o flag de boot, o processo tModLoader.dll e o socket TCP na porta 7777 via /proc/net/tcp
PORT="${TMOD_PORT:-7777}"
HEX_PORT=$(printf '%04X' "$PORT")

# 1. Verifica se o flag de boot concluído existe
if [ ! -f /tmp/server_healthy ]; then
    exit 1
fi

# 2. Verifica se o processo do tModLoader está rodando e não está em estado Zumbi (Z)
TMOD_PID=$(pgrep -f "tModLoader.dll" | head -n 1)
if [ -z "$TMOD_PID" ]; then
    exit 1
fi

PROC_STATE=$(ps -o stat= -p "$TMOD_PID" 2>/dev/null | tr -d ' ')
if [[ "$PROC_STATE" == Z* ]]; then
    exit 1
fi

# 3. Verifica se a porta TCP 7777 (0x1E61) está em estado LISTEN (0A) na pilha de rede do kernel
if ! grep -qiE ":${HEX_PORT} [0-9A-F]+:[0-9A-F]+ 0A" /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
    exit 1
fi

exit 0
