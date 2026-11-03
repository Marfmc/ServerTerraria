#!/bin/bash
# ==============================================================================
# Entrypoint Resiliente para Servidor Dedicado Terraria (tModLoader 1.4)
# - Auto-Restore Anti-Corrupção e Backups Automáticos (.zip)
# - Resolução Inteligente de Mods e Coleções da Steam (Mods/install.txt)
# - Modo Seguro e Diagnóstico de Mods (Crash Loop)
# - Watchdog Anti-Travamento e Anti-Carregamento Infinito
# - Notificações Automáticas via Discord Webhook
# ==============================================================================

cd /terraria-server || exit 1

pipe=/tmp/tmod.pipe
console_log=/tmp/current_console.log
configPath=/terraria-server/serverconfig.txt
BOOT_FAIL_FILE=/data/tModLoader/.boot_failures
INSTALL_HASH_FILE=/data/tModLoader/.install_txt.md5
DISABLED_FAULTY_FILE=/data/tModLoader/.disabled_faulty_mods.txt

BACKUP_INTERVAL_MINUTES="${BACKUP_INTERVAL_MINUTES:-180}"
BOOT_TIMEOUT_SECONDS="${TMOD_BOOT_TIMEOUT:-600}"
TMOD_AUTOSAVE_INTERVAL="${TMOD_AUTOSAVE_INTERVAL:-10}"
TMOD_PORT="${TMOD_PORT:-7777}"
SHUTTING_DOWN=0

rm -f /tmp/server_healthy "$console_log"
mkdir -p /data/tModLoader/Worlds /data/tModLoader/Mods /data/Backups /terraria-server/tModLoader-Logs /data/steamMods/steamapps/workshop/content/1281930

echo "=================================================================="
echo "   INICIANDO SERVIDOR DEDICADO TERRARIA (tModLoader 1.4 Docker)   "
echo "=================================================================="
echo "[SYSTEM] Mundo configurado : ${TMOD_WORLDNAME:-MundoPrincipal}"
echo "[SYSTEM] Intervalo Autosave: ${TMOD_AUTOSAVE_INTERVAL} minutos"
echo "[SYSTEM] Backup Automático : a cada ${BACKUP_INTERVAL_MINUTES} minutos (mantendo os últimos ${BACKUP_KEEP_COUNT:-10})"

# 1. Verifica se Mods/install.txt foi alterado pelo usuário para resetar o Modo Seguro
if [ -f /data/tModLoader/Mods/install.txt ]; then
    current_hash=$(md5sum /data/tModLoader/Mods/install.txt | awk '{print $1}')
    old_hash=$(cat "$INSTALL_HASH_FILE" 2>/dev/null || echo "")
    if [ "$current_hash" != "$old_hash" ]; then
        echo "$current_hash" > "$INSTALL_HASH_FILE"
        echo 0 > "$BOOT_FAIL_FILE"
        if [ -f "$DISABLED_FAULTY_FILE" ]; then
            echo "[MODS] Alteração detectada em Mods/install.txt! Limpando isolamento do Modo Seguro."
            rm -f "$DISABLED_FAULTY_FILE"
        fi
    fi
fi

# 2. Verifica histórico de falhas de boot consecutivas (Crash Loop / Corrupção)
boot_fails=$(cat "$BOOT_FAIL_FILE" 2>/dev/null || echo 0)
if ! [[ "$boot_fails" =~ ^[0-9]+$ ]]; then
    boot_fails=0
fi

if [ "$boot_fails" -ge 1 ]; then
    echo "[WATCHDOG] Detectada(s) ${boot_fails} falha(s) de inicialização consecutiva(s) anterior(es)."
    crash_type=$(python3 /terraria-server/scripts/diagnose_crash.py type 2>/dev/null || echo "NONE")
    if [ "$crash_type" == "WORLD_CORRUPT" ]; then
        echo "[WATCHDOG] ⚠️ O log anterior indica falha ao carregar o arquivo do mundo! Acionando Auto-Restore..."
        /terraria-server/scripts/backup_manager.sh check-and-restore force
    fi

    if [ "$boot_fails" -ge 3 ]; then
        echo "[WATCHDOG] ⚠️ 3 falhas seguidas no carregamento! Executando diagnóstico de Modo Seguro de Mods..."
        diag_output=$(python3 /terraria-server/scripts/diagnose_crash.py isolate)
        echo "$diag_output"
        python3 /terraria-server/scripts/discord_notify.py crash_mod "$diag_output"
        echo 0 > "$BOOT_FAIL_FILE"
        boot_fails=0
    else
        python3 /terraria-server/scripts/diagnose_crash.py check
    fi
fi

# 3. Verificação de integridade do mundo e Backup de Inicialização
/terraria-server/scripts/backup_manager.sh check-and-restore
/terraria-server/scripts/backup_manager.sh create boot

# 4. Resolução, Download e Ativação Automática de Mods (Mods/install.txt + Coleções + Dependências)
python3 /terraria-server/scripts/resolve_mods.py

# 5. Geração limpa do serverconfig.txt (evita duplicação de linhas em reinícios)
if [[ "$TMOD_USECONFIGFILE" == "Yes" ]]; then
    if [ ! -e /terraria-server/customconfig.txt ]; then
        echo "[!!] FATAL: TMOD_USECONFIGFILE=Yes, mas /terraria-server/customconfig.txt não foi encontrado."
        sleep 5s
        exit 1
    fi
else
    rm -f "$configPath"
    touch "$configPath"
    /terraria-server/prepare-config.sh
fi

# 6. Função de Desligamento Seguro (Graceful Shutdown)
function shutdown() {
    if [ "$SHUTTING_DOWN" -eq 1 ]; then
        return
    fi
    SHUTTING_DOWN=1
    echo ""
    echo "[SYSTEM] 🛑 Sinal de desligamento recebido! Salvando o mundo com segurança..."
    rm -f /tmp/server_healthy

    if pgrep -f "tModLoader.dll" >/dev/null 2>&1; then
        inject "say ${TMOD_SHUTDOWN_MESSAGE:-Servidor desligando! Salvando o mundo...}" 2>/dev/null || true
        inject "save" 2>/dev/null || true
        sleep 3s
        inject "exit" 2>/dev/null || true

        # Aguarda até 25 segundos para o tModLoader encerrar após salvar
        for _ in $(seq 1 50); do
            if ! pgrep -f "tModLoader.dll" >/dev/null 2>&1; then
                break
            fi
            sleep 0.5
        done
    fi

    echo "[SYSTEM] Criando backup de desligamento na pasta Backups/..."
    /terraria-server/scripts/backup_manager.sh create shutdown
    python3 /terraria-server/scripts/discord_notify.py offline
    rm -f "$pipe"
    echo "[SYSTEM] ✅ Servidor encerrado e mundo salvo com sucesso!"
    exit 0
}

trap shutdown TERM INT

# 7. Incrementa contador de tentativa de boot (será zerado assim que o servidor ficar Online)
echo $((boot_fails + 1)) > "$BOOT_FAIL_FILE"

server="/terraria-server/LaunchUtils/ScriptCaller.sh -server -tmlsavedirectory \"/data/tModLoader\" -steamworkshopfolder \"/data/steamMods/steamapps/workshop\" -config \"$configPath\""

rm -f "$pipe"
mkfifo "$pipe"
touch "$console_log"

echo "[SYSTEM] Iniciando motor do tModLoader Server..."
tmux new-session -d "$server 2>&1 | tee -a $console_log > $pipe"

# Inicia o Autosave nativo em background
/terraria-server/autosave.sh &
AUTOSAVE_PID=$!

# Redireciona o pipe para o stdout do container (para aparecer no docker logs)
cat "$pipe" &

# 8. Loop Principal do Watchdog (Boot Timeout + Anti-Freeze Porta 7777 + Backup Periódico 180 min)
SERVER_ONLINE=0
boot_elapsed=0
freeze_strikes=0
backup_elapsed=0
backup_interval_sec=$((BACKUP_INTERVAL_MINUTES * 60))

while [ "$SHUTTING_DOWN" -eq 0 ]; do
    sleep 5
    if [ "$SHUTTING_DOWN" -eq 1 ]; then
        break
    fi

    # Verifica se o processo do tModLoader ou a sessão tmux fechou inesperadamente
    if ! tmux has-session 2>/dev/null; then
        if [ "$SHUTTING_DOWN" -eq 0 ]; then
            echo "[WATCHDOG] ⚠️ A sessão do servidor tModLoader foi encerrada inesperadamente!"
            if [ "$SERVER_ONLINE" -eq 0 ]; then
                python3 /terraria-server/scripts/diagnose_crash.py check
            fi
            kill "$AUTOSAVE_PID" 2>/dev/null || true
            exit 1
        fi
        break
    fi

    if [ "$SERVER_ONLINE" -eq 0 ]; then
        boot_elapsed=$((boot_elapsed + 5))

        # Detecta erro de mundo corrompido durante o boot
        if grep -qiE "Load Failed!|World file is corrupt" "$console_log" 2>/dev/null; then
            echo "[WATCHDOG] ⚠️ Erro 'Load Failed!' detectado ao abrir o mundo! Restaurando backup automaticamente..."
            inject "exit" 2>/dev/null || true
            sleep 2
            /terraria-server/scripts/backup_manager.sh check-and-restore force
            echo 0 > "$BOOT_FAIL_FILE"
            exit 1
        fi

        # Detecta quando o servidor terminou de carregar e abriu a porta 7777
        if grep -qE "Listening on port|Server started" "$console_log" 2>/dev/null; then
            SERVER_ONLINE=1
            echo 0 > "$BOOT_FAIL_FILE"
            touch /tmp/server_healthy
            echo "=================================================================="
            echo "[SYSTEM] 🟢 SERVIDOR ONLINE E PRONTO NA PORTA ${TMOD_PORT}!"
            if [ -n "${RADMIN_IP:-}" ]; then
                echo "[SYSTEM] 🌐 IP Radmin VPN: ${RADMIN_IP}:${TMOD_PORT}"
            fi
            echo "=================================================================="
            python3 /terraria-server/scripts/discord_notify.py online &
            continue
        fi

        # Proteção contra Carregamento Infinito no Boot
        if [ "$boot_elapsed" -ge "$BOOT_TIMEOUT_SECONDS" ]; then
            echo "[WATCHDOG] ⚠️ Tempo limite de inicialização (${BOOT_TIMEOUT_SECONDS}s) excedido! Reiniciando servidor..."
            python3 /terraria-server/scripts/discord_notify.py watchdog "Tempo limite de inicialização (${BOOT_TIMEOUT_SECONDS}s) excedido (Carregamento Infinito)."
            tmux kill-session 2>/dev/null || true
            exit 1
        fi
    else
        # Servidor já está Online: monitora congelamento na porta 7777 e agenda backups periódicos
        backup_elapsed=$((backup_elapsed + 5))

        # Verifica a cada 30 segundos se o servidor e o socket na porta 7777 estão saudáveis
        if [ $((backup_elapsed % 30)) -eq 0 ]; then
            if /terraria-server/scripts/healthcheck.sh >/dev/null 2>&1; then
                freeze_strikes=0
            else
                freeze_strikes=$((freeze_strikes + 1))
                echo "[WATCHDOG] ⚠️ Aviso: Porta ${TMOD_PORT} não respondeu (${freeze_strikes}/3)..."
                if [ "$freeze_strikes" -ge 3 ]; then
                    echo "[WATCHDOG] 🚨 Congelamento confirmado na porta ${TMOD_PORT}! Tentando salvar o mundo e reiniciar..."
                    rm -f /tmp/server_healthy
                    inject "save" 2>/dev/null || true
                    sleep 5
                    inject "exit" 2>/dev/null || true
                    sleep 5
                    /terraria-server/scripts/backup_manager.sh create watchdog
                    python3 /terraria-server/scripts/discord_notify.py watchdog "A porta ${TMOD_PORT} parou de responder por 90 segundos."
                    tmux kill-session 2>/dev/null || true
                    exit 1
                fi
            fi
        fi

        # Backup Periódico Automático (padrão: a cada 180 minutos)
        if [ "$backup_elapsed" -ge "$backup_interval_sec" ]; then
            backup_elapsed=0
            echo "[BACKUP] 🕒 Iniciando backup periódico automático (${BACKUP_INTERVAL_MINUTES} min)..."
            inject "save" 2>/dev/null || true
            sleep 5
            /terraria-server/scripts/backup_manager.sh create periodico
        fi
    fi
done
