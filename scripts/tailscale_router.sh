#!/bin/sh
# ==============================================================================
# Roteador Interno do Container Tailscale (vpn_tailscale)
# - Mantém o container Tailscale independente do ciclo de vida do servidor_tmodloader
#   (reiniciar o Terraria pelo Portainer ou Watchdog NUNCA derruba a VPN).
# - Encaminha automaticamente:
#     * Porta 7777 (TCP/UDP) -> tmodloader:7777 (Jogo Terraria)
#     * Porta 9443 (TCP)     -> portainer:9443  (Painel Web Portainer)
# - Exporta o IP 100.x.y.z ativo para /terraria-logs/.tailscale_ip para o Discord.
# ==============================================================================

rm -f /terraria-logs/.tailscale_ip 2>/dev/null || true

(
    LAST_TMOD_IP=""
    LAST_PORT_IP=""

    while true; do
        sleep 4

        # 1. Atualiza o arquivo compartilhado com o IP 100.x.y.z ativo do Tailscale
        TS_IP=$(tailscale ip -4 2>/dev/null | grep -E '^100\.' | head -n 1)
        if [ -n "$TS_IP" ]; then
            echo "$TS_IP" > /terraria-logs/.tailscale_ip 2>/dev/null || true
        else
            rm -f /terraria-logs/.tailscale_ip 2>/dev/null || true
        fi

        # 2. Resolve os IPs atuais dos containers na rede bridge do Docker Compose
        TMOD_IP=$(getent hosts tmodloader 2>/dev/null | awk '{print $1}' | head -n 1)
        PORT_IP=$(getent hosts portainer 2>/dev/null | awk '{print $1}' | head -n 1)

        if [ -z "$TMOD_IP" ] && [ -z "$PORT_IP" ]; then
            continue
        fi

        # 3. Garante que o encaminhamento de pacotes pela interface tailscale0 está liberado
        iptables -C FORWARD -i tailscale0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i tailscale0 -j ACCEPT 2>/dev/null || true
        iptables -C FORWARD -o tailscale0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o tailscale0 -j ACCEPT 2>/dev/null || true
        if iptables -L ts-forward >/dev/null 2>&1; then
            iptables -C ts-forward -i tailscale0 -j ACCEPT 2>/dev/null || iptables -I ts-forward 1 -i tailscale0 -j ACCEPT 2>/dev/null || true
            iptables -C ts-forward -o tailscale0 -j ACCEPT 2>/dev/null || iptables -I ts-forward 1 -o tailscale0 -j ACCEPT 2>/dev/null || true
        fi

        # 4. Atualiza as regras DNAT (7777 -> tmodloader, 9443 -> portainer) se algum IP mudou
        if [ "$TMOD_IP" != "$LAST_TMOD_IP" ] || [ "$PORT_IP" != "$LAST_PORT_IP" ] || ! iptables -t nat -L TS_PORT_FWD >/dev/null 2>&1; then
            iptables -t nat -N TS_PORT_FWD 2>/dev/null || true
            iptables -t nat -F TS_PORT_FWD 2>/dev/null || true

            if [ -n "$TMOD_IP" ]; then
                iptables -t nat -A TS_PORT_FWD -i tailscale0 -p tcp --dport 7777 -j DNAT --to-destination "${TMOD_IP}:7777" 2>/dev/null || true
                iptables -t nat -A TS_PORT_FWD -i tailscale0 -p udp --dport 7777 -j DNAT --to-destination "${TMOD_IP}:7777" 2>/dev/null || true
            fi

            if [ -n "$PORT_IP" ]; then
                iptables -t nat -A TS_PORT_FWD -i tailscale0 -p tcp --dport 9443 -j DNAT --to-destination "${PORT_IP}:9443" 2>/dev/null || true
            fi

            iptables -t nat -C PREROUTING -j TS_PORT_FWD 2>/dev/null || iptables -t nat -A PREROUTING -j TS_PORT_FWD 2>/dev/null || true
            iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -j MASQUERADE 2>/dev/null || true

            LAST_TMOD_IP="$TMOD_IP"
            LAST_PORT_IP="$PORT_IP"
        fi
    done
) &

exec /usr/local/bin/containerboot

