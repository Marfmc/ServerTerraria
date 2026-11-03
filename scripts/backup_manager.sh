#!/bin/bash
# ==============================================================================
# Gerenciador de Backups (.zip), Rotação (Últimos 10) e Auto-Restore Anti-Corrupção
# ==============================================================================

WORLDS_DIR="/data/tModLoader/Worlds"
BACKUPS_DIR="/data/Backups"
WORLD_NAME="${TMOD_WORLDNAME:-MundoPrincipal}"
MAX_BACKUPS="${BACKUP_KEEP_COUNT:-10}"

mkdir -p "$WORLDS_DIR" "$BACKUPS_DIR"

log() {
    echo -e "[BACKUP] $1"
}

is_world_valid() {
    local wld_file="$WORLDS_DIR/${WORLD_NAME}.wld"
    local twld_file="$WORLDS_DIR/${WORLD_NAME}.twld"

    if [ ! -f "$wld_file" ]; then
        return 1
    fi

    local wld_size
    wld_size=$(stat -c%s "$wld_file" 2>/dev/null || echo 0)
    if [ "$wld_size" -lt 1024 ]; then
        log "⚠️ Arquivo ${WORLD_NAME}.wld está com tamanho inválido (${wld_size} bytes)!"
        return 1
    fi

    # Verifica cabeçalho mínimo (arquivos .wld do Terraria possuem assinatura 'relogic' nos primeiros bytes)
    if [ -f "$twld_file" ]; then
        local twld_size
        twld_size=$(stat -c%s "$twld_file" 2>/dev/null || echo 0)
        if [ "$twld_size" -gt 0 ] && [ "$twld_size" -lt 64 ]; then
            log "⚠️ Arquivo ${WORLD_NAME}.twld parece truncado/corrompido (${twld_size} bytes)!"
            return 1
        fi
    fi

    return 0
}

rotate_backups() {
    local count
    count=$(ls -1t "$BACKUPS_DIR"/backup_"${WORLD_NAME}"_*.zip 2>/dev/null | wc -l)
    if [ "$count" -gt "$MAX_BACKUPS" ]; then
        local to_delete=$((count - MAX_BACKUPS))
        log "Rotacionando backups: mantendo os ${MAX_BACKUPS} mais recentes (removendo ${to_delete} antigo(s))..."
        ls -1t "$BACKUPS_DIR"/backup_"${WORLD_NAME}"_*.zip 2>/dev/null | tail -n +"$((MAX_BACKUPS + 1))" | while read -r old_zip; do
            rm -f "$old_zip"
            log "🗑️ Removido backup antigo: $(basename "$old_zip")"
        done
    fi
}

create_backup() {
    local reason="${1:-auto}"
    local wld_file="$WORLDS_DIR/${WORLD_NAME}.wld"
    local twld_file="$WORLDS_DIR/${WORLD_NAME}.twld"

    if ! is_world_valid; then
        log "Nenhum mundo válido encontrado em ${wld_file} para fazer backup agora."
        return 1
    fi

    local timestamp
    timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    local zip_name="backup_${WORLD_NAME}_${timestamp}_${reason}.zip"
    local zip_path="$BACKUPS_DIR/$zip_name"

    cd "$WORLDS_DIR" || return 1
    local files_to_zip=("${WORLD_NAME}.wld")
    if [ -f "$twld_file" ]; then
        files_to_zip+=("${WORLD_NAME}.twld")
    fi

    if zip -q "$zip_path" "${files_to_zip[@]}"; then
        if unzip -t -qq "$zip_path" >/dev/null 2>&1; then
            log "✅ Backup criado com sucesso: $zip_name"
            rotate_backups
            return 0
        else
            log "⚠️ Falha na verificação do arquivo zip gerado. Removendo arquivo incompleto."
            rm -f "$zip_path"
            return 1
        fi
    else
        log "⚠️ Erro ao compactar backup do mundo."
        return 1
    fi
}

restore_latest_valid() {
    local latest_backups
    latest_backups=$(ls -1t "$BACKUPS_DIR"/backup_"${WORLD_NAME}"_*.zip 2>/dev/null)

    if [ -z "$latest_backups" ]; then
        # Tenta usar o .wld.bak nativo do Terraria caso exista e não haja .zip
        if [ -f "$WORLDS_DIR/${WORLD_NAME}.wld.bak" ]; then
            local bak_size
            bak_size=$(stat -c%s "$WORLDS_DIR/${WORLD_NAME}.wld.bak" 2>/dev/null || echo 0)
            if [ "$bak_size" -ge 1024 ]; then
                cp -f "$WORLDS_DIR/${WORLD_NAME}.wld.bak" "$WORLDS_DIR/${WORLD_NAME}.wld"
                [ -f "$WORLDS_DIR/${WORLD_NAME}.twld.bak" ] && cp -f "$WORLDS_DIR/${WORLD_NAME}.twld.bak" "$WORLDS_DIR/${WORLD_NAME}.twld"
                log "🛠️ Restaurado a partir do arquivo .bak nativo do Terraria."
                python3 /terraria-server/scripts/discord_notify.py restore "${WORLD_NAME}.wld.bak"
                return 0
            fi
        fi
        log "⚠️ Nenhum backup anterior encontrado em $BACKUPS_DIR para restaurar."
        return 1
    fi

    while read -r zip_candidate; do
        [ -z "$zip_candidate" ] && continue
        if unzip -t -qq "$zip_candidate" >/dev/null 2>&1; then
            log "🛠️ Restaurando backup íntegro: $(basename "$zip_candidate")..."
            unzip -o -q "$zip_candidate" -d "$WORLDS_DIR"
            log "✅ Mundo restaurado com sucesso a partir de $(basename "$zip_candidate")!"
            python3 /terraria-server/scripts/discord_notify.py restore "$(basename "$zip_candidate")"
            return 0
        else
            log "⚠️ Backup $(basename "$zip_candidate") está corrompido, tentando o anterior..."
        fi
    done <<< "$latest_backups"

    log "❌ Não foi encontrado nenhum arquivo .zip íntegro para restaurar."
    return 1
}

check_and_restore() {
    local force_flag="${1:-}"
    local wld_file="$WORLDS_DIR/${WORLD_NAME}.wld"
    local has_backups
    has_backups=$(ls -1 "$BACKUPS_DIR"/backup_"${WORLD_NAME}"_*.zip 2>/dev/null | wc -l)

    if [ "$force_flag" == "force" ]; then
        log "⚠️ Restauração forçada acionada por erro de carregamento do mundo!"
        restore_latest_valid
        return $?
    fi

    if [ ! -f "$wld_file" ]; then
        if [ "$has_backups" -gt 0 ]; then
            log "⚠️ Mundo ${WORLD_NAME}.wld ausente, mas existem ${has_backups} backup(s) na pasta Backups/. Restaurando automaticamente..."
            restore_latest_valid
            return $?
        else
            log "Primeiro início detectado (nenhum mundo ou backup existente ainda)."
            return 0
        fi
    fi

    if ! is_world_valid; then
        log "⚠️ Corrupção detectada nos arquivos do mundo! Iniciando Auto-Restore..."
        restore_latest_valid
        return $?
    fi

    log "Verificação de integridade do mundo '${WORLD_NAME}': OK."
    return 0
}

restore_specific() {
    local target_zip="$1"
    if [ -z "$target_zip" ]; then
        log "❌ Especifique o nome do arquivo .zip para restaurar."
        return 1
    fi

    # Aceita tanto caminho completo quanto apenas o nome do arquivo dentro de /data/Backups
    if [ ! -f "$target_zip" ]; then
        target_zip="$BACKUPS_DIR/$(basename "$target_zip")"
    fi

    if [ ! -f "$target_zip" ]; then
        log "❌ Arquivo de backup não encontrado: $target_zip"
        return 1
    fi

    if ! unzip -t -qq "$target_zip" >/dev/null 2>&1; then
        log "❌ O arquivo $(basename "$target_zip") está corrompido e não pode ser restaurado."
        return 1
    fi

    log "Restaurando manualmente o backup: $(basename "$target_zip")..."
    unzip -o -q "$target_zip" -d "$WORLDS_DIR"
    log "✅ Backup $(basename "$target_zip") restaurado com sucesso na pasta Worlds!"
    return 0
}

case "${1:-}" in
    create)
        create_backup "${2:-manual}"
        ;;
    check-and-restore)
        check_and_restore "${2:-}"
        ;;
    restore)
        restore_specific "${2:-}"
        ;;
    list)
        ls -1t "$BACKUPS_DIR"/backup_"${WORLD_NAME}"_*.zip 2>/dev/null | xargs -r -n1 basename
        ;;
    *)
        echo "Uso: $0 {create [motivo]|check-and-restore [force]|restore <arquivo.zip>|list}"
        exit 1
        ;;
esac

