#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Analisador de Falhas de Inicialização e Diagnóstico de Mods (Modo Seguro)
Inspeciona /terraria-server/tModLoader-Logs/server.log para detectar:
1. Corrupção de mundo (Load Failed! / WorldFile exception)
2. Qual mod específico causou exceção durante o carregamento
"""

import json
import os
import re
import sys

SERVER_LOG = os.environ.get("TMOD_SERVER_LOG_PATH", "/terraria-server/tModLoader-Logs/server.log")
DIAG_FILE = "/terraria-server/tModLoader-Logs/diagnostico_mods.txt"
ENABLED_JSON = "/data/tModLoader/Mods/enabled.json"
DISABLED_FAULTY_FILE = "/data/tModLoader/.disabled_faulty_mods.txt"


def analyze_log() -> tuple[str, str, str]:
    """
    Retorna (tipo_erro, mod_suspeito, resumo_erro)
    tipo_erro: 'NONE' | 'WORLD_CORRUPT' | 'MOD_CRASH' | 'GENERIC_CRASH'
    """
    if not os.path.exists(SERVER_LOG):
        return "NONE", "", "Arquivo server.log não encontrado."

    try:
        with open(SERVER_LOG, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
    except Exception as e:
        return "NONE", "", f"Erro ao ler server.log: {e}"

    if "Listening on port" in content or "Server started" in content:
        return "NONE", "", ""

    # 1. Verifica corrupção de mundo
    world_corrupt_patterns = [
        r"Load Failed!",
        r"World file is corrupt",
        r"at Terraria\.IO\.WorldFile\.LoadWorld",
        r"at Terraria\.ModLoader\.IO\.WorldIO\.Load",
    ]
    for pat in world_corrupt_patterns:
        if re.search(pat, content, re.IGNORECASE):
            return "WORLD_CORRUPT", "", "Falha ao carregar o arquivo do mundo (.wld/.twld corrompido)."

    # Carrega lista de mods ativos em enabled.json para cruzar com o stack trace (suporta UTF-8 com ou sem BOM do Windows)
    enabled_mods = []
    if os.path.exists(ENABLED_JSON):
        try:
            with open(ENABLED_JSON, "r", encoding="utf-8-sig") as f:
                data = json.load(f)
                if isinstance(data, list):
                    enabled_mods = [str(x) for x in data]
        except Exception:
            pass

    lines = content.splitlines()
    error_lines = []
    for idx, line in enumerate(lines):
        if "[ERROR]" in line or "Exception" in line or "Error:" in line:
            error_lines.extend(lines[idx : min(len(lines), idx + 18)])
            break

    error_snippet = "\n".join(error_lines[:18]).strip()
    if not error_snippet and lines:
        error_snippet = "\n".join(lines[-15:]).strip()

    # 2. Tenta identificar qual mod causou o erro
    suspect_mod = ""
    # Procura nos mods ativos se algum aparece no trecho de erro
    for mod in enabled_mods:
        if re.search(rf"\b{re.escape(mod)}\b", error_snippet):
            suspect_mod = mod
            break

    # Se não achou no stack trace, procura a última linha de "Loading/Instantiating/Adding Recipes"
    if not suspect_mod:
        for line in reversed(lines):
            for mod in enabled_mods:
                if mod in line and ("Loading" in line or "Mod" in line or "Recipes" in line):
                    suspect_mod = mod
                    break
            if suspect_mod:
                break

    # Fallback caso enabled.json esteja vazio: extrai da linha 'Loading <ModName>' antes do erro
    if not suspect_mod:
        for line in reversed(lines):
            m = re.search(r"\[tML\]:\s+(?:Loading|Instantiating)\s+([A-Za-z0-9_]+)", line)
            if m and m.group(1) not in ("ModLoader", "Terraria"):
                suspect_mod = m.group(1)
                break

    if suspect_mod:
        return "MOD_CRASH", suspect_mod, error_snippet
    if error_lines:
        return "GENERIC_CRASH", "", error_snippet
    return "NONE", "", ""


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "check"
    err_type, suspect_mod, snippet = analyze_log()

    if mode == "type":
        print(err_type)
        return 0

    if err_type == "NONE":
        return 0

    report_lines = [
        "==================================================================",
        "          DIAGNÓSTICO AUTOMÁTICO DE FALHA NO SERVIDOR             ",
        "==================================================================",
        f"Tipo de Falha Detectada : {err_type}",
        f"Mod Suspeito Identificado: {suspect_mod or 'Não identificado especificamente'}",
        "------------------------------------------------------------------",
        "Trecho do Erro no server.log:",
        snippet or "(Sem stack trace detalhado)",
        "==================================================================",
    ]

    if mode == "isolate" and suspect_mod:
        os.makedirs(os.path.dirname(DISABLED_FAULTY_FILE), exist_ok=True)
        existing = set()
        if os.path.exists(DISABLED_FAULTY_FILE):
            with open(DISABLED_FAULTY_FILE, "r", encoding="utf-8", errors="ignore") as f:
                existing = {l.strip() for l in f if l.strip()}
        if suspect_mod not in existing:
            with open(DISABLED_FAULTY_FILE, "a", encoding="utf-8") as f:
                f.write(f"{suspect_mod}\n")
        report_lines.append(
            f"🛑 AÇÃO DO MODO SEGURO: O mod '{suspect_mod}' causou 3 falhas seguidas "
            f"e foi isolado temporariamente para permitir que o servidor inicie."
        )
        report_lines.append(
            "Dica: Edite o arquivo Mods/install.txt para limpar o isolamento do Modo Seguro."
        )
        report_lines.append("==================================================================")

    report = "\n".join(report_lines)
    try:
        with open(DIAG_FILE, "w", encoding="utf-8") as f:
            f.write(report + "\n")
    except Exception:
        pass

    print(report, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

