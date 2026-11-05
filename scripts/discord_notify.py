#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Notificador de Status via Discord Webhook (Opcional)
Se DISCORD_WEBHOOK_URL estiver configurado no ambiente, envia Embeds formatados.
"""

import datetime
import json
import os
import re
import subprocess
import sys
import urllib.request

SUMMARY_FILE = "/tmp/active_mods_summary.txt"


def detect_tailscale_ip() -> str:
    shared_ip_file = "/terraria-server/tModLoader-Logs/.tailscale_ip"
    if os.path.exists(shared_ip_file):
        try:
            with open(shared_ip_file, "r", encoding="utf-8", errors="ignore") as f:
                ip = f.read().strip()
                if re.match(r"^100\.", ip):
                    return ip
        except Exception:
            pass
    env_ip = os.environ.get("TAILSCALE_IP", "").strip()
    if env_ip:
        return env_ip
    try:
        out = subprocess.check_output(["hostname", "-I"], text=True, timeout=3)
        for token in out.split():
            if re.match(r"^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d+\.\d+$", token.strip()):
                return token.strip()
    except Exception:
        pass
    return ""


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


def read_progression_summary() -> str:
    try:
        out = subprocess.check_output(
            ["python3", "/terraria-server/scripts/nameless_deity.py", "summary-line"],
            text=True,
            timeout=5,
        ).strip()
        if out:
            return out
    except Exception:
        pass
    return "Use `/progresso` no Discord ou `!progresso` no chat do jogo."


def send_webhook(url: str, payload: dict) -> None:
    try:
        if "username" not in payload:
            payload["username"] = "Nameless Deity"
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
    provider = os.environ.get("NETWORK_PROVIDER", "radmin").strip().lower()
    radmin_ip = os.environ.get("RADMIN_IP", "").strip()
    tailscale_ip = detect_tailscale_ip()

    address_lines = []
    if radmin_ip:
        address_lines.append(f"**Radmin:** `{radmin_ip}:{port}`")
    if tailscale_ip:
        address_lines.append(f"**Tailscale:** `{tailscale_ip}:{port}`")

    if address_lines:
        connect_address = "\n".join(address_lines)
        if radmin_ip and tailscale_ip:
            network_label = "🌐 Endereços (Híbrido)"
        elif tailscale_ip:
            network_label = "🌐 Endereço (Tailscale VPN)"
        else:
            network_label = "🌐 Endereço (Radmin VPN)"
    else:
        if provider == "tailscale":
            network_label = "🌐 Endereço (Tailscale VPN)"
            connect_address = f"Porta `{port}` (Verifique IP `100.x.y.z` no Tailscale)"
        elif provider == "local":
            network_label = "🌐 Endereço (Rede Local / Direto)"
            connect_address = f"Porta `{port}` (LAN / Port Forwarding)"
        else:
            network_label = "🌐 Endereço (Radmin VPN)"
            connect_address = f"Porta `{port}` (Verifique IP `26.x.y.z` no Radmin VPN)"

    now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()

    if event == "online":
        mods_text = read_mods_summary()
        prog_text = read_progression_summary()
        embed = {
            "title": "🟢 Servidor Terraria (tModLoader) Online!",
            "description": "O mundo foi carregado e o servidor já está aceitando conexões.",
            "color": 0x2ECC71,
            "fields": [
                {"name": network_label, "value": connect_address, "inline": True},
                {"name": "🔑 Senha", "value": f"`{password}`" if password != "N/A" else "Sem senha", "inline": True},
                {"name": "🗺️ Mundo", "value": f"`{world_name}` (Máx: {max_players})", "inline": True},
                {"name": "🧩 Mods Ativos", "value": mods_text, "inline": False},
                {"name": "👁️ Guardião da Progressão (Nameless Deity)", "value": f"{prog_text}\n*(Comandos: `/progresso`, `/proximo`, `/bosses`, `/objetivos` ou com `!` no chat do jogo)*", "inline": False},
            ],
            "footer": {"text": "Nameless Deity • Servidor Dedicado tModLoader"},
            "timestamp": now_iso,
        }
    elif event == "offline":
        prog_text = read_progression_summary()
        embed = {
            "title": "🔴 Servidor Terraria Desligado",
            "description": (
                f"O mundo **`{world_name}`** foi salvo com segurança e um backup `.zip` atualizado "
                f"foi guardado na pasta `Backups/`.\n\n{prog_text}\n{extra_msg}"
            ).strip(),
            "color": 0xE74C3C,
            "footer": {"text": "Nameless Deity • Servidor Dedicado tModLoader"},
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

