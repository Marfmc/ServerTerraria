#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Notificador de Status via Discord Webhook (Opcional)
Se DISCORD_WEBHOOK_URL estiver configurado no ambiente, envia Embeds formatados.
"""

import datetime
import json
import os
import sys
import urllib.request

SUMMARY_FILE = "/tmp/active_mods_summary.txt"


def read_mods_summary() -> str:
    if os.path.exists(SUMMARY_FILE):
        try:
            with open(SUMMARY_FILE, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read().strip()
                if content:
                    return content[:950] + ("\n..." if len(content) > 950 else "")
        except Exception:
            pass
    return "Nenhum (Vanilla)"


def send_webhook(url: str, payload: dict) -> None:
    try:
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            headers={
                "Content-Type": "application/json",
                "User-Agent": "tModLoader-Docker-Notifier/1.0",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as _:
            pass
        print("[DISCORD] Notificação enviada com sucesso.", flush=True)
    except Exception as e:
        print(f"[DISCORD] Aviso: falha ao enviar notificação ao Discord: {e}", flush=True)


def main() -> int:
    webhook_url = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
    if not webhook_url or not webhook_url.startswith("http"):
        return 0

    event = sys.argv[1] if len(sys.argv) > 1 else "info"
    extra_msg = sys.argv[2] if len(sys.argv) > 2 else ""

    world_name = os.environ.get("TMOD_WORLDNAME", "MundoPrincipal")
    port = os.environ.get("TMOD_PORT", "7777")
    password = os.environ.get("TMOD_PASS", "N/A")
    max_players = os.environ.get("TMOD_MAXPLAYERS", "8")
    radmin_ip = os.environ.get("RADMIN_IP", "").strip() or "Verifique no Radmin VPN"

    connect_address = f"`{radmin_ip}:{port}`" if radmin_ip != "Verifique no Radmin VPN" else f"Porta `{port}` (IP da Rede Radmin VPN)"
    now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()

    if event == "online":
        mods_text = read_mods_summary()
        embed = {
            "title": "🟢 Servidor Terraria (tModLoader) Online!",
            "description": "O mundo foi carregado e o servidor já está aceitando conexões.",
            "color": 0x2ECC71,
            "fields": [
                {"name": "🌐 Endereço (Radmin VPN)", "value": connect_address, "inline": True},
                {"name": "🔑 Senha", "value": f"`{password}`" if password != "N/A" else "Sem senha", "inline": True},
                {"name": "🗺️ Mundo", "value": f"`{world_name}` (Máx: {max_players})", "inline": True},
                {"name": "🧩 Mods Ativos", "value": mods_text, "inline": False},
            ],
            "footer": {"text": "Servidor Dedicado tModLoader •"},
            "timestamp": now_iso,
        }
    elif event == "offline":
        embed = {
            "title": "🔴 Servidor Terraria Desligado",
            "description": (
                f"O mundo **`{world_name}`** foi salvo com segurança e um backup `.zip` atualizado "
                f"foi guardado na pasta `Backups/`.\n{extra_msg}"
            ).strip(),
            "color": 0xE74C3C,
            "footer": {"text": "Servidor Dedicado tModLoader"},
            "timestamp": now_iso,
        }
    elif event == "restore":
        embed = {
            "title": "🛠️ Auto-Restore de Backup Executado!",
            "description": (
                f"Foi detectada uma falha/corrupção nos arquivos do mundo **`{world_name}`**.\n"
                f"O sistema restaurou automaticamente o backup íntegro mais recente:\n"
                f"📦 `{extra_msg}`"
            ),
            "color": 0xF39C12,
            "footer": {"text": "Sistema Anti-Corrupção tModLoader"},
            "timestamp": now_iso,
        }
    elif event == "crash_mod":
        embed = {
            "title": "⚠️ Alerta de Falha no Carregamento / Diagnóstico de Mods",
            "description": (
                "O servidor falhou repetidamente ao iniciar. Veja o diagnóstico identificado nos logs:\n"
                f"```\n{extra_msg[:1500]}\n```"
            ),
            "color": 0xE67E22,
            "footer": {"text": "Modo Seguro de Mods tModLoader"},
            "timestamp": now_iso,
        }
    elif event == "watchdog":
        embed = {
            "title": "🔄 Watchdog: Reinício Automático de Recuperação",
            "description": (
                f"O monitoramento detectou travamento ou tempo limite excedido:\n"
                f"**Motivo:** {extra_msg}\n"
                f"Tentando salvar o mundo `{world_name}` e reiniciando automaticamente..."
            ),
            "color": 0x3498DB,
            "footer": {"text": "Watchdog Anti-Freeze tModLoader"},
            "timestamp": now_iso,
        }
    else:
        embed = {
            "title": "ℹ️ Aviso do Servidor Terraria",
            "description": extra_msg or "Evento registrado no servidor.",
            "color": 0x95A5A6,
            "timestamp": now_iso,
        }

    send_webhook(webhook_url, {"embeds": [embed]})
    return 0


if __name__ == "__main__":
    sys.exit(main())

