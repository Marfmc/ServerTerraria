#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Gerenciador Inteligente de Mods para tModLoader (Docker)
- Lê /data/tModLoader/Mods/install.txt (aceita IDs, links de mods e links de Coleções da Steam)
- Expande Coleções da Steam automaticamente via API pública da Steam Workshop
- Descobre e inclui dependências obrigatórias de cada mod automaticamente
- Baixa/atualiza via SteamCMD (com retry individual caso algum falhe)
- Inspeciona os arquivos .tmod baixados e gera /data/tModLoader/Mods/enabled.json automaticamente
"""

import glob
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request

INSTALL_TXT_PATH = "/data/tModLoader/Mods/install.txt"
MODS_DIR = "/data/tModLoader/Mods"
ENABLED_JSON_PATH = "/data/tModLoader/Mods/enabled.json"
WORKSHOP_BASE_DIR = "/data/steamMods"
WORKSHOP_CONTENT_DIR = "/data/steamMods/steamapps/workshop/content/1281930"
SUMMARY_FILE = "/tmp/active_mods_summary.txt"
DISABLED_FAULTY_FILE = "/data/tModLoader/.disabled_faulty_mods.txt"

STEAM_COLLECTION_API = "https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/"
STEAM_FILE_DETAILS_API = "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"


def log(msg: str) -> None:
    print(f"[MODS] {msg}", flush=True)


def extract_ids_from_line(line: str) -> list[str]:
    # Remove comentários iniciados por # ou // (desde que não seja https://)
    line = re.sub(r"#.*$", "", line)
    line = re.sub(r"(?<!:)//.*$", "", line).strip()
    if not line:
        return []

    found = []
    # 1. Procura parâmetros ?id=XXXX ou &id=XXXX em links da Steam
    url_ids = re.findall(r"[?&]id=(\d{6,15})", line)
    if url_ids:
        found.extend(url_ids)
    else:
        # 2. Procura números isolados (IDs diretos ou separados por vírgula/espaço)
        raw_ids = re.findall(r"\b(\d{6,15})\b", line)
        found.extend(raw_ids)

    return found


def read_initial_ids() -> list[str]:
    ids = []

    #Garante que o arquivo install.txt exista com cabeçalho instrutivo se estiver vazio
    os.makedirs(MODS_DIR, exist_ok=True)
    if not os.path.exists(INSTALL_TXT_PATH) or os.path.getsize(INSTALL_TXT_PATH) == 0:
        try:
            with open(INSTALL_TXT_PATH, "w", encoding="utf-8") as f:
                f.write(
                    "# ==================================================================\n"
                    "# LISTA AUTOMÁTICA DE MODS E COLEÇÕES (STEAM WORKSHOP)\n"
                    "# ==================================================================\n"
                    "# Cole abaixo (um por linha):\n"
                    "#   - O ID numérico do Mod (ex: 2824688072)\n"
                    "#   - O link completo do Mod na Steam\n"
                    "#   - O link ou ID de uma Coleção da Steam (Workshop Collection)\n"
                    "#\n"
                    "# O servidor baixará os mods, suas dependências obrigatórias e\n"
                    "# ativará tudo sozinho no enabled.json ao iniciar!\n"
                    "# ==================================================================\n"
                )
        except Exception as e:
            log(f"Aviso ao criar cabeçalho no install.txt: {e}")

    if os.path.exists(INSTALL_TXT_PATH):
        with open(INSTALL_TXT_PATH, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                for mod_id in extract_ids_from_line(line):
                    if mod_id not in ids:
                        ids.append(mod_id)

    # Também considera variáveis de ambiente do docker-compose se preenchidas
    for env_var in ("TMOD_AUTODOWNLOAD", "TMOD_ENABLEDMODS"):
        val = os.environ.get(env_var, "").strip()
        if val:
            for mod_id in extract_ids_from_line(val):
                if mod_id not in ids:
                    ids.append(mod_id)

    return ids


def post_steam_api(url: str, params: dict) -> dict:
    try:
        data = urllib.parse.urlencode(params).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            headers={"User-Agent": "tModLoader-Docker-Manager/1.0"},
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        log(f"Aviso: falha ao consultar API da Steam ({url}): {e}")
        return {}


def expand_collections(initial_ids: list[str]) -> list[str]:
    """Expande coleções da Steam (inclusive sub-coleções) em IDs de mods individuais."""
    if not initial_ids:
        return []

    expanded = []
    queue = list(initial_ids)
    visited_collections = set()

    while queue:
        batch = queue[:50]
        queue = queue[50:]

        params = {"collectioncount": len(batch)}
        for idx, cid in enumerate(batch):
            params[f"publishedfileids[{idx}]"] = cid

        res = post_steam_api(STEAM_COLLECTION_API, params)
        details = res.get("response", {}).get("collectiondetails", [])

        handled_in_batch = set()
        for entry in details:
            cid = str(entry.get("publishedfileid", ""))
            children = entry.get("children", [])
            if entry.get("result") == 1 and children:
                handled_in_batch.add(cid)
                visited_collections.add(cid)
                log(f"Coleção da Steam detectada ({cid}): expandindo {len(children)} itens...")
                for child in children:
                    child_id = str(child.get("publishedfileid", ""))
                    filetype = child.get("filetype", 0)
                    if not child_id:
                        continue
                    if filetype == 2:  # Sub-coleção
                        if child_id not in visited_collections:
                            queue.append(child_id)
                    else:
                        if child_id not in expanded:
                            expanded.append(child_id)

        for cid in batch:
            if cid not in handled_in_batch and cid not in visited_collections:
                if cid not in expanded:
                    expanded.append(cid)

    return expanded


def resolve_dependencies_and_titles(mod_ids: list[str]) -> tuple[list[str], dict[str, str]]:
    """Consulta GetPublishedFileDetails para obter títulos e incluir dependências obrigatórias."""
    if not mod_ids:
        return [], {}

    all_ids = list(mod_ids)
    titles: dict[str, str] = {}
    checked = set()
    depth = 0

    while depth < 4:
        to_check = [mid for mid in all_ids if mid not in checked]
        if not to_check:
            break

        new_deps = []
        for i in range(0, len(to_check), 50):
            batch = to_check[i : i + 50]
            params = {"itemcount": len(batch)}
            for idx, mid in enumerate(batch):
                params[f"publishedfileids[{idx}]"] = mid
                checked.add(mid)

            res = post_steam_api(STEAM_FILE_DETAILS_API, params)
            file_details = res.get("response", {}).get("publishedfiledetails", [])
            for item in file_details:
                mid = str(item.get("publishedfileid", ""))
                title = item.get("title", "").strip()
                if mid and title:
                    titles[mid] = title

                # children em um item de Workshop são as dependências obrigatórias
                for child in item.get("children", []):
                    dep_id = str(child.get("publishedfileid", ""))
                    if dep_id and dep_id not in all_ids and dep_id not in new_deps:
                        new_deps.append(dep_id)
                        log(f"Dependência obrigatória detectada para '{title or mid}': ID {dep_id}")

        # Dependências devem ser carregadas antes/junto com os mods principais
        all_ids = new_deps + all_ids
        depth += 1

    # Busca título de eventuais dependências adicionadas na última iteração
    unchecked = [mid for mid in all_ids if mid not in titles]
    if unchecked:
        params = {"itemcount": len(unchecked)}
        for idx, mid in enumerate(unchecked):
            params[f"publishedfileids[{idx}]"] = mid
        res = post_steam_api(STEAM_FILE_DETAILS_API, params)
        for item in res.get("response", {}).get("publishedfiledetails", []):
            mid = str(item.get("publishedfileid", ""))
            title = item.get("title", "").strip()
            if mid and title:
                titles[mid] = title

    return all_ids, titles


def find_tmod_for_workshop_id(mod_id: str) -> list[str]:
    """Retorna os nomes internos (sem .tmod) encontrados na pasta do Workshop para um ID."""
    target_dir = os.path.join(WORKSHOP_CONTENT_DIR, str(mod_id))
    if not os.path.isdir(target_dir):
        return []

    # Procura arquivos .tmod diretamente na pasta ou em subpastas de versão (ex: 2024.8/*.tmod)
    tmod_files = glob.glob(os.path.join(target_dir, "**", "*.tmod"), recursive=True)
    if not tmod_files:
        return []

    # Se houver múltiplas versões em subpastas (ex: 1.4.3 vs 1.4.4/2026.x), pega a subpasta mais recente
    subdirs = sorted(
        [d for d in glob.glob(os.path.join(target_dir, "*")) if os.path.isdir(d)]
    )
    if subdirs:
        latest_subdir = subdirs[-1]
        sub_tmods = glob.glob(os.path.join(latest_subdir, "*.tmod"))
        if sub_tmods:
            tmod_files = sub_tmods

    names = []
    for path in tmod_files:
        name = os.path.splitext(os.path.basename(path))[0]
        if name and name not in names:
            names.append(name)
    return names


def download_workshop_mods(mod_ids: list[str], titles: dict[str, str]) -> None:
    if not mod_ids:
        return

    log(f"Iniciando download/atualização de {len(mod_ids)} mod(s) via SteamCMD...")
    cmd = [
        "steamcmd",
        "+force_install_dir",
        WORKSHOP_BASE_DIR,
        "+login",
        "anonymous",
    ]
    for mid in mod_ids:
        cmd.extend(["+workshop_download_item", "1281930", str(mid)])
    cmd.append("+quit")

    subprocess.run(cmd, check=False)

    # Verifica se algum mod falhou no download em lote e tenta individualmente (até 2 tentativas)
    for mid in mod_ids:
        if not find_tmod_for_workshop_id(mid):
            title = titles.get(mid, mid)
            log(f"Mod '{title}' ({mid}) não encontrado após download em lote. Tentando download individual...")
            for attempt in range(1, 3):
                subprocess.run(
                    [
                        "steamcmd",
                        "+force_install_dir",
                        WORKSHOP_BASE_DIR,
                        "+login",
                        "anonymous",
                        "+workshop_download_item",
                        "1281930",
                        str(mid),
                        "+quit",
                    ],
                    check=False,
                )
                if find_tmod_for_workshop_id(mid):
                    log(f"Download individual de '{title}' ({mid}) concluído na tentativa {attempt}!")
                    break


def main() -> int:
    initial_ids = read_initial_ids()

    # Verifica também se há arquivos .tmod colocados manualmente em /data/tModLoader/Mods
    manual_tmods = glob.glob(os.path.join(MODS_DIR, "*.tmod"))
    manual_mod_names = [
        os.path.splitext(os.path.basename(p))[0] for p in sorted(manual_tmods)
    ]

    if not initial_ids and not manual_mod_names:
        log("Nenhum mod configurado em Mods/install.txt (Servidor Vanilla/Puro).")
        with open(ENABLED_JSON_PATH, "w", encoding="utf-8") as f:
            json.dump([], f, indent=2)
        with open(SUMMARY_FILE, "w", encoding="utf-8") as f:
            f.write("Nenhum (Vanilla)")
        return 0

    log(f"IDs lidos de Mods/install.txt: {', '.join(initial_ids) if initial_ids else 'Nenhum'}")

    expanded_ids = expand_collections(initial_ids)
    resolved_ids, titles = resolve_dependencies_and_titles(expanded_ids)

    if resolved_ids:
        download_workshop_mods(resolved_ids, titles)

    # Verifica se há mods isolados pelo Modo Seguro
    disabled_faulty = set()
    if os.path.exists(DISABLED_FAULTY_FILE):
        with open(DISABLED_FAULTY_FILE, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    disabled_faulty.add(line)

    enabled_names = []
    summary_lines = []

    for mid in resolved_ids:
        names = find_tmod_for_workshop_id(mid)
        title = titles.get(mid, f"Mod {mid}")
        if not names:
            log(f"⚠️ ERRO: Não foi possível localizar o arquivo .tmod para '{title}' (ID {mid}).")
            continue
        for internal_name in names:
            if internal_name in disabled_faulty:
                log(f"🛑 MODO SEGURO: Mod '{internal_name}' ({title}) foi pulado por causar crash anterior.")
                continue
            if internal_name not in enabled_names:
                enabled_names.append(internal_name)
                summary_lines.append(f"• {title} (`{internal_name}`)")
                log(f"✅ Ativado: {title} -> nome interno '{internal_name}' (ID {mid})")

    for internal_name in manual_mod_names:
        if internal_name in disabled_faulty:
            log(f"🛑 MODO SEGURO: Mod manual '{internal_name}' foi pulado por causar crash anterior.")
            continue
        if internal_name not in enabled_names:
            enabled_names.append(internal_name)
            summary_lines.append(f"• {internal_name} (Arquivo local)")
            log(f"✅ Ativado (Local): '{internal_name}'")

    with open(ENABLED_JSON_PATH, "w", encoding="utf-8") as f:
        json.dump(enabled_names, f, indent=2, ensure_ascii=False)

    with open(SUMMARY_FILE, "w", encoding="utf-8") as f:
        if summary_lines:
            f.write("\n".join(summary_lines))
        else:
            f.write("Nenhum (Vanilla)")

    log(f"Arquivo Mods/enabled.json atualizado automaticamente com {len(enabled_names)} mod(s)!")
    return 0


if __name__ == "__main__":
    sys.exit(main())

