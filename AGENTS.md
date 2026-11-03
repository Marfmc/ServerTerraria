# Contexto do Projeto: Servidor Dedicado Terraria (tModLoader Docker)

> **Instrução para o Agente:** Mantenha este arquivo (`AGENTS.md`) sempre atualizado quando novas funcionalidades, correções técnicas, scripts ou decisões de arquitetura forem implementadas no projeto.

---

## 1. Visão e Requisitos Principais do Usuário
O objetivo deste projeto é ser um servidor de Terraria (tModLoader 1.4) **100% portátil, resiliente e "1-clique"**:
1. **Automação Total (One-Click):** Tudo deve funcionar com o clicar de um botão (`.bat`), incluindo verificação/instalação de dependências de ambiente (Docker Desktop, WSL2 e Radmin VPN) quando necessário.
2. **Gerenciamento Fácil de Mods:** Adicionar, atualizar e ativar mods deve exigir apenas colar IDs, links de mods ou links de Coleções da Steam no `Mods/install.txt`.
3. **Alta Resiliência (Anti-Crash & Anti-Freeze):** Proteção contra quedas, travamentos silenciosos e loops de carregamento infinito na inicialização ou durante o jogo, garantindo salvamento seguro do mundo.
4. **Acesso Remoto Simples:** Conexão via **Radmin VPN** (com liberação automática das portas `7777` para o jogo e `9443` para administração remota no Portainer no Firewall do Windows).

---

## 2. Arquitetura Atual e Fatos Técnicos Importantes

### Container e Imagem (`Dockerfile` + `docker-compose.yml`)
* **Imagem Base:** `jacobsmile/tmodloader1.4:latest` (Linux Ubuntu/Debian x64, rodando .NET 8.0).
* **Pacotes Adicionais no `Dockerfile`:** `libicu-dev`, `zip`, `unzip`, `curl`, `python3`, `procps`, `ca-certificates`.
* **Correção Crítica do .NET 8 (`libicu-dev`):**
  * A imagem base não possui a biblioteca `libicu` instalada por padrão.
  * **NUNCA** utilize `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` no `docker-compose.yml`. Embora faça o .NET 8 iniciar sem `libicu`, o código do Terraria (`Terraria.Localization.GameCulture`) tenta instanciar a cultura `en-US` logo no boot e sofre crash imediato (`CultureNotFoundException`).
  * A solução correta e ativa está no `Dockerfile` na raiz do projeto, que instala `libicu-dev` via `apt-get`, sendo construído via `build: .` no `docker-compose.yml`.

### Estrutura de Pastas, Volumes e Scripts
* `Worlds/` -> Mapeado para `/data/tModLoader/Worlds`. Contém os arquivos do mundo (`MundoPrincipal.wld` e `MundoPrincipal.twld`). Ignorado no Git (exceto `.gitkeep`).
* `Backups/` -> Mapeado para `/data/Backups`. Contém snapshots `.zip` do mundo (`.wld` + `.twld`), mantendo os últimos 10 backups. Ignorado no Git (exceto `.gitkeep`).
* `Mods/` -> Mapeado para `/data/tModLoader/Mods`.
  * `install.txt`: Aceita IDs numéricos, links de mods individuais ou links de Coleções da Oficina Steam (um por linha).
  * `enabled.json`: Gerado/atualizado automaticamente a partir dos mods baixados pelo `install.txt`.
* `Logs/` -> Mapeado para `/terraria-server/tModLoader-Logs`. Contém `server.log`, `Launch.log`, `Natives.log`, `environment-server.log`, `diagnostico_mods.txt` e backups de logs antigos em `Logs/Old/`.
* `scripts/` -> Contém toda a inteligência de automação:
  * `entrypoint_custom.sh`: Substitui `/terraria-server/entrypoint.sh` na imagem Docker. Coordena a verificação de integridade, auto-restore, resolução de mods, geração limpa do `serverconfig.txt`, Watchdog de boot/runtime, backups periódicos a cada 180 min e desligamento seguro (`save` + `exit` + backup `.zip`).
  * `resolve_mods.py`: Lê `Mods/install.txt`, consulta a API da Steam Workshop para expandir Coleções e dependências obrigatórias, baixa via `steamcmd` (com retry individual) e preenche `Mods/enabled.json`.
  * `backup_manager.sh`: Cria backups `.zip`, gerencia a rotação mantendo os últimos 10 arquivos e realiza o Auto-Restore caso detecte `.wld`/`.twld` ausente ou corrompido.
  * `diagnose_crash.py`: Analisa `server.log` em caso de falha de inicialização, identifica corrupção de mundo ou qual mod causou exceção e isola automaticamente mods problemáticos após 3 falhas seguidas (Modo Seguro).
  * `discord_notify.py`: Envia Embeds formatados para `DISCORD_WEBHOOK_URL` (Online, Offline, Auto-Restore, Watchdog e Crash de Mod).
  * `healthcheck.sh`: Verifica se o servidor concluiu o boot, se o processo `tModLoader.dll` está ativo e se a porta TCP `7777` está respondendo.
  * `gerenciador_windows.ps1`: Motor de automação no Windows (chamado pelos arquivos `.bat`), responsável por verificar/instalar Docker Desktop, WSL2 e Radmin VPN, liberar portas `7777` e `9443` no Firewall, detectar o IP `26.x.x.x` do Radmin VPN e fornecer o menu interativo.

---

## 3. Especificação dos Atalhos `.bat` na Raiz
1. **`IniciarServidor.bat`:** Chama `gerenciador_windows.ps1 -Action Start` (verifica/instala dependências, abre Radmin VPN, libera Firewall, sobe os containers e acompanha os logs em tempo real até o servidor ficar Online).
2. **`DesligarServidor.bat`:** Chama `gerenciador_windows.ps1 -Action Stop` (envia `save` e `exit` com timeout de 45s, gera backup `.zip` na pasta `Backups/` e notifica no Discord).
3. **`PainelMenu.bat`:** Chama `gerenciador_windows.ps1 -Action Menu` (menu interativo completo para iniciar, desligar, forçar backup, restaurar backups da lista, ver logs/diagnóstico e enviar comandos ao console do Terraria).
