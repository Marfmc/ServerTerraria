# Contexto do Projeto: Servidor Dedicado Terraria (tModLoader Docker)

> **Instrução para o Agente:** Mantenha este arquivo (`AGENTS.md`) sempre atualizado quando novas funcionalidades, correções técnicas, scripts ou decisões de arquitetura forem implementadas no projeto.

---

## 1. Visão e Requisitos Principais do Usuário
O objetivo deste projeto é ser um servidor de Terraria (tModLoader 1.4) **100% portátil, resiliente e "1-clique"**:
1. **Automação Total (One-Click):** Tudo deve funcionar com o clicar de um botão (`.bat`), incluindo seleção do modo de rede e verificação/instalação de dependências de ambiente (Docker Desktop, WSL2 e Radmin VPN) quando necessário.
2. **Gerenciamento Fácil de Mods:** Adicionar, atualizar e ativar mods deve exigir apenas colar IDs, links de mods ou links de Coleções da Steam no `Mods/install.txt`.
3. **Alta Resiliência (Anti-Crash & Anti-Freeze):** Proteção contra quedas, travamentos silenciosos e loops de carregamento infinito na inicialização ou durante o jogo, garantindo salvamento seguro do mundo.
4. **Acesso Remoto Multi-Provedor com Tailscale Containerizado Independente (`radmin` | `tailscale` | `hybrid` | `local`):** Conexão via **Radmin VPN** no host (`26.0.0.0/8`), **Tailscale VPN 100% em Container Docker** (`vpn_tailscale` rodando `scripts/tailscale_router.sh` para encaminhar `7777` -> `tmodloader:7777` e `9443` -> `portainer:9443` via `iptables` DNAT na rede do Docker Compose, imune a reinícios do container do Terraria), **Modo Híbrido** (ambos simultaneamente + contingência automática se o Radmin falhar) ou **Apenas Local**.

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
  * `resolve_mods.py`: Lê `Mods/install.txt`, consulta a API da Steam Workshop para expandir Coleções e dependências obrigatórias, baixa via `steamcmd` (com retry individual) e preenche `Mods/enabled.json`. Inclui ordenação semântica/natural (`version_sort_key`) para subpastas de versão de mods (garantindo que versões como `2024.10` tenham precedência correta sobre `2024.8`).
  * `backup_manager.sh`: Cria backups `.zip`, gerencia a rotação mantendo os últimos 10 arquivos e realiza o Auto-Restore caso detecte `.wld`/`.twld` ausente ou corrompido.
  * `diagnose_crash.py`: Analisa `server.log` em caso de falha de inicialização, identifica corrupção de mundo ou qual mod causou exceção e isola automaticamente mods problemáticos após 3 falhas seguidas (Modo Seguro).
  * `discord_notify.py`: Envia Embeds formatados para `DISCORD_WEBHOOK_URL` (Online com IPs do Radmin e/ou Tailscale conforme o provedor ativo + resumo de progressão do Nameless Deity, Offline, Auto-Restore, Watchdog e Crash de Mod).
  * `nameless_deity.py`: Guardião da Progressão Linear e Bot do Discord temático (`Nameless Deity`) integrado ao container sem exigir dependências externas:
    * Mantém a linha do tempo linear de Bosses (Vanilla + Calamity Mod + Addons como Wrath of the Gods, Catalyst e Hunt of the Old God) com itens de invocação e biomas, além de Marcos da Campanha (Shimmer, Abismo, Labs de Draedon, Eventos) e Metas Customizadas (`Worlds/<Mundo>_progression.json`, incluído automaticamente nos backups `.zip`).
    * Sincroniza automaticamente bosses derrotados lendo o arquivo binário `.twld` (parser GZip NBT nativo) e monitorando o `server.log` / console em tempo real.
    * Responde a comandos tanto dentro do **Chat do Jogo** (`!progresso`, `!proximo`, `!bosses`, `!objetivos`, `!marcar <alvo>`, `!desmarcar <alvo>`, `!meta <texto>`) via `inject "say ..."` + Webhook quanto diretamente no **Discord** (via `DISCORD_BOT_TOKEN` com Slash Commands `/progresso`, `/proximo`, `/bosses`, `/objetivos`, `/marcar`, `/desmarcar`, `/meta` e comandos de prefixo).
  * `healthcheck.sh`: Verifica se o servidor concluiu o boot, se o processo `tModLoader.dll` está ativo e se a porta TCP `7777` está respondendo.
  * `gerenciador_windows.ps1`: Motor de automação no Windows (chamado pelos arquivos `.bat`), responsável por:
    * **Seletor e Persistência de Provedor de Rede (`Select-NetworkProvider`):** Permite escolher entre `radmin` (app Windows), `tailscale` (container Docker `vpn_tailscale` no `docker-compose.yml`), `hybrid` (Radmin + Container Tailscale simultâneos) ou `local` antes da verificação de dependências. Salva a escolha em `NETWORK_PROVIDER` no `.env` e exibe um countdown não-bloqueante de 4s nas inicializações seguintes.
    * **Container Router Tailscale (`vpn_tailscale` + `scripts/tailscale_router.sh` + `Ensure-TailscaleContainer` + `Configure-TailscaleAuthKey`):** O serviço `tailscale` (`tailscale/tailscale:stable`) roda com rede própria na bridge do Docker Compose (sem `network_mode: service:tmodloader`, para que reiniciar o Terraria pelo Portainer ou Watchdog nunca derrube a VPN), expõe `41641/udp` para facilitar conexões P2P diretas via WireGuard, encaminha `7777` (TCP/UDP) para `tmodloader:7777` e `9443` (TCP) para `portainer:9443`, e grava o IP ativo em `Logs/.tailscale_ip`. Permite autenticação automática e silenciosa via `TS_AUTHKEY` no `.env` (solicitada de forma guiada no terminal caso não esteja configurada) ou autorização interativa via navegador com detecção e abertura automática do link de login (`login.tailscale.com`).
    * **Camada Extra de Fallback Automático (`Ensure-NetworkEnvironment`):** Se o Radmin VPN falhar ou não retornar IP (`26.x.x.x`), oferece ativar imediatamente o container Tailscale no Docker Compose como contingência (`hybrid`).
    * **Firewall Zero-Trust (`Ensure-FirewallRules`):** Libera as portas `7777` (TCP/UDP) e `9443` (TCP) restritas às faixas `26.0.0.0/8` e `LocalSubnet` quando necessário, além da porta `41641` (UDP) para permitir conexões diretas P2P do Tailscale WireGuard sem cair em relay DERP.
    * **Central de Atualização em 2 Canais (`Update-TerrariaServer`):** Ação `-Action Update` (opção `[11]` do menu) que oferece um menu didático:
      * **[1] Atualização Padrão (Docker Hub):** Baixa imagens atualizadas (`docker pull` para `jacobsmile/tmodloader1.4:latest`, `tailscale` e `portainer`) e reconstrói o container tModLoader com `--pull`.
      * **[2] Forçar Atualização Oficial do tModLoader (GitHub Releases - Contingência):** Baixa os binários oficiais estáveis do GitHub (`tModLoader.zip`) da versão mais recente ou escolhida (ex: `9.3.1` / `v2026.09.3.1`), gravando `TMOD_OFFICIAL_VERSION` no `.env` e passando como build arg para o `Dockerfile`. Resolve imediatamente o erro de versão diferente (*"Your game is using 9.3.1 and the server 9.2.1"*) mesmo que o Docker Hub ainda não tenha atualizado.
      * **[3] Resetar para Imagem Padrão do Docker Hub:** Limpa `TMOD_OFFICIAL_VERSION` no `.env` e recompila o container voltando a usar 100% a imagem pura do Docker Hub.
    * Verificar/instalar Docker Desktop, WSL2 e Radmin VPN (`Famatech.RadminVPN`) via Winget, fornecer o menu interativo (com exibição da versão ativa do tModLoader no cabeçalho, opção `[10]` para trocar provedor de rede, `[11]` para a Central de Atualização e `[12]` para gerenciar o Guardião `Nameless Deity` / configurar `DISCORD_BOT_TOKEN`) e reverter tudo (`-Action Uninstall`, opção `[9]` do menu: remove regras de Firewall, containers `servidor_tmodloader`, `gerenciador_portainer`, `vpn_tailscale`, volumes e imagens do projeto).
  * **Contexto de uso:** o PC de desenvolvimento do usuário NÃO é o servidor; o servidor roda em outra máquina. Evite deixar alterações de sistema (firewall, containers) no PC de desenvolvimento.
  * `testar_servidor.ps1`: Bateria de 13 testes automatizados ponta a ponta que valida todas as funções do servidor (incluindo o parser `.twld` NBT e comandos do `nameless_deity.py`), exibe resultados em verde/vermelho com logs detalhados e limpa 100% dos arquivos temporários de teste ao finalizar.
  * `testar_bot_nameless.ps1`: Bancada de testes e simulador interativo isolado para o Bot `Nameless Deity` (sobe apenas o bot sem exigir o container do Terraria, simula conquistas `.twld`/logs/marcos/metas, abre painel estilo `PainelMenu` para testar Slash Commands no Discord e, ao encerrar, apaga automaticamente todas as mensagens de teste do canal do Discord e restaura os arquivos locais ao estado inicial).

---

## 3. Especificação dos Atalhos `.bat` na Raiz
1. **`IniciarServidor.bat`:** Chama `gerenciador_windows.ps1 -Action Start` (verifica/instala dependências, abre Radmin VPN, libera Firewall, sobe os containers e acompanha os logs em tempo real até o servidor ficar Online).
2. **`DesligarServidor.bat`:** Chama `gerenciador_windows.ps1 -Action Stop` (envia `save` e `exit` com timeout de 45s, gera backup `.zip` na pasta `Backups/` e notifica no Discord).
3. **`PainelMenu.bat`:** Chama `gerenciador_windows.ps1 -Action Menu` (menu interativo completo para iniciar, desligar, forçar backup, restaurar backups da lista, ver logs/diagnóstico, enviar comandos ao console e atualizar imagens).
4. **`AtualizarServidor.bat`:** Chama `gerenciador_windows.ps1 -Action Update` (atualiza as imagens base via `docker pull` e reconstrói o container com `--pull`).
