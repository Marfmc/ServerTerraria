================================================================================
          SERVIDOR DEDICADO TERRARIA (tModLoader 1.4) - DOCKER 1-CLIQUE
================================================================================

1. O QUE É ESTE PROJETO?
--------------------------------------------------------------------------------
Este projeto é uma estrutura 100% portátil, automatizada e resiliente para rodar
um servidor dedicado de Terraria com Mods (tModLoader 1.4) utilizando Docker no
Windows.

Ele foi projetado para eliminar configurações manuais complexas e proteger o
progresso do mundo contra falhas, oferecendo:

  * Automação 1-Clique (Bootstrapper): Verifica e instala automaticamente as
    dependências de ambiente no Windows (Docker Desktop, WSL2 e Radmin VPN) e
    libera as portas necessárias no Firewall do Windows sem esforço manual.
  * Gerenciamento Inteligente de Mods: Basta colar IDs, links de mods ou links
    de Coleções da Steam no arquivo "Mods/install.txt". O servidor expande
    coleções, descobre dependências obrigatórias, baixa tudo via SteamCMD e
    preenche o "Mods/enabled.json" sozinho.
  * Alta Resiliência (Watchdog + Modo Seguro): Monitora travamentos na porta
    7777 e loops de carregamento infinito. Se um mod causar 3 falhas seguidas no
    boot, o servidor identifica o mod culpado nos logs e o isola temporariamente
    para não impedir a abertura do servidor.
  * Backups Automáticos + Auto-Restore: Compacta o mundo (.wld e .twld) em
    arquivos .zip na pasta "Backups/" ao iniciar, ao desligar e a cada 180
    minutos, mantendo os últimos 10 backups e restaurando automaticamente o
    mais recente caso detecte corrupção nos arquivos do mundo.
  * Acesso à Distância (Radmin VPN + Portainer): Detecta automaticamente o IP da
    sua rede Radmin VPN (26.x.x.x) para seus amigos jogarem na porta 7777 e
    permite administração remota via navegador na porta 9443.
  * Avisos no Discord (Webhook): Envia notificações automáticas quando o
    servidor fica Online (com IP, senha e lista de mods), quando desliga ou se
    ocorrer algum alerta de backup/mod.


2. MAPA DE PASTAS E ARQUIVOS
--------------------------------------------------------------------------------
ServerTerraria_espelho/
│
├── IniciarServidor.bat                # Botão 1-clique para ligar e atualizar tudo
├── DesligarServidor.bat               # Botão 1-clique para salvar o mundo, fazer backup e desligar
├── PainelMenu.bat                     # Menu interativo no terminal (Backups, Restore, Logs, Comandos)
├── Gerenciador Online(Portainer).url  # Atalho para o painel web local (https://localhost:9443)
│
├── docker-compose.yml                 # Configurações do mundo, senha, portas, backups e Discord
├── Dockerfile                         # Imagem customizada com suporte a .NET 8 (libicu-dev) e scripts
├── AGENTS.md                          # Memória técnica e regras de arquitetura para o Agente de IA
├── README.txt                         # Este guia completo de documentação do projeto
├── .gitignore / .dockerignore         # Filtros para ignorar mundos, backups, logs e mods baixados no Git
│
├── Worlds/                            # [Volume] Arquivos ativos do mundo gerado
│   ├── MundoPrincipal.wld             # Mundo base do Terraria
│   └── MundoPrincipal.twld            # Dados dos blocos e itens de Mods do mundo
│
├── Backups/                           # [Volume] Histórico automático de snapshots do mundo
│   └── backup_<Mundo>_<Data>.zip      # Mantém automaticamente os 10 backups mais recentes
│
├── Mods/                              # [Volume] Controle de Modificações (Steam Workshop)
│   ├── install.txt                    # ÚNICO arquivo que você edita (IDs, links de mods ou coleções)
│   └── enabled.json                   # Lista interna de ativação (gerada e atualizada sozinha)
│
├── Logs/                              # [Volume] Histórico e diagnósticos do servidor
│   ├── server.log                     # Log principal da sessão atual do tModLoader
│   ├── diagnostico_mods.txt           # Relatório gerado automaticamente se algum mod travar o boot
│   └── Old/                           # Logs de sessões anteriores compactados (.zip)
│
└── scripts/                           # Motor de automação interna (Windows + Container Linux)
    ├── gerenciador_windows.ps1        # Automação Windows (Radmin, Firewall, Docker e Menu Interativo)
    ├── entrypoint_custom.sh           # Ciclo de vida do servidor, Watchdog e Graceful Shutdown
    ├── resolve_mods.py                # Expansão de Coleções/Dependências da Steam e geração do enabled.json
    ├── backup_manager.sh              # Criação de .zip, rotação de 10 cópias e Auto-Restore
    ├── diagnose_crash.py              # Analisador de logs e isolamento de mods defeituosos (Modo Seguro)
    ├── discord_notify.py              # Envio de avisos formatados (Embeds) para o Discord
    └── healthcheck.sh                 # Verificação silenciosa de saúde do processo e da porta 7777


3. COMO INICIAR E DESLIGAR O SERVIDOR (USO DIÁRIO)
--------------------------------------------------------------------------------
A) Para LIGAR o servidor:
   1. Dê dois cliques em "IniciarServidor.bat".
   2. O script verificará se o Docker Desktop e o Radmin VPN estão instalados e
      abertos (instalando-os se necessário) e liberará as portas 7777 e 9443 no
      Firewall do Windows.
   3. Acompanhe o carregamento na tela até aparecer a mensagem verde:
      "[ONLINE] SERVIDOR TERRARIA PRONTO PARA JOGAR!"

B) Para DESLIGAR o servidor:
   1. Dê dois cliques em "DesligarServidor.bat" (NUNCA desligue forçando o
      fechamento do Docker sem salvar).
   2. O script enviará os comandos "save" e "exit" ao Terraria, aguardará o
      salvamento completo do mundo e criará um arquivo .zip na pasta "Backups/".

C) Usando o Painel de Controle Interativo ("PainelMenu.bat"):
   Abra o "PainelMenu.bat" a qualquer momento para:
   - [1] Iniciar / Atualizar Servidor
   - [2] Desligar Servidor com Segurança (Salva Mundo + Backup)
   - [3] Forçar um Backup .zip do Mundo Agora
   - [4] Restaurar um Backup Antigo (escolhendo entre os 10 últimos salvos)
   - [5] Ver Logs ao Vivo e Diagnóstico de Mods
   - [6] Enviar Comandos para o Console do Terraria (ex: "say Olá", "noon", "save")
   - [7] Abrir o Painel Web (Portainer)


4. COMO CONECTAR AO SERVIDOR (LOCAL E À DISTÂNCIA)
--------------------------------------------------------------------------------
* Para você (jogando no mesmo PC do servidor):
  Abra o tModLoader -> Multiplayer -> Join via IP -> Digite: 127.0.0.1 (Porta: 7777)

* Para seus amigos (à distância via Radmin VPN):
  1. Crie uma rede no aplicativo Radmin VPN (ou entre na mesma rede que seus amigos).
  2. Ao iniciar o "IniciarServidor.bat", o painel mostrará o seu IP do Radmin
     (exemplo: 26.45.120.15:7777).
  3. Seus amigos só precisam estar conectados na mesma rede do Radmin VPN e
     digitar esse IP (26.x.x.x) e a porta 7777 no tModLoader.

* Administração Remota (Portainer):
  Você pode gerenciar os containers pelo navegador acessando:
  - No próprio PC: https://localhost:9443
  - De outro PC na rede Radmin: https://<SEU_IP_RADMIN>:9443


5. COMO ADICIONAR OU REMOVER MODS E COLEÇÕES
--------------------------------------------------------------------------------
Você NÃO precisa descobrir o nome interno dos mods nem editar o "enabled.json"
ou o "docker-compose.yml". Tudo é feito em um único lugar:

1. Abra o arquivo "Mods/install.txt" no Bloco de Notas.
2. Em cada linha, cole qualquer uma das opções abaixo:
   - Apenas o ID do mod:
     2824688072
   - O link completo do mod na Oficina Steam:
     https://steamcommunity.com/sharedfiles/filedetails/?id=2824688072
   - O link ou ID de uma COLEÇÃO DA STEAM (Workshop Collection):
     https://steamcommunity.com/sharedfiles/filedetails/?id=XXXXXXXXXX
3. Salve o arquivo "Mods/install.txt" e execute o "IniciarServidor.bat".

O que o servidor fará sozinho ao iniciar:
  - Identificará se o link/ID é uma Coleção e listará todos os mods dentro dela.
  - Consultará na Steam se algum mod exige outros mods (dependências) e os
    incluirá automaticamente.
  - Baixará/atualizará tudo via SteamCMD e preencherá o "Mods/enabled.json".


6. PERSONALIZANDO O MUNDO E CONFIGURAÇÕES (docker-compose.yml)
--------------------------------------------------------------------------------
Para alterar configurações do mundo ou do servidor, edite o arquivo
"docker-compose.yml" na raiz da pasta:

  * TMOD_WORLDNAME=MundoPrincipal  -> Nome do mundo (carrega existente ou cria um novo)
  * TMOD_WORLDSIZE=2               -> Tamanho ao criar mundo novo (1=Pequeno, 2=Médio, 3=Grande)
  * TMOD_DIFFICULTY=0              -> Dificuldade (0=Clássico, 1=Expert, 2=Master, 3=Jornada)
  * TMOD_MAXPLAYERS=8              -> Limite máximo de jogadores simultâneos
  * TMOD_PASS=suasenha             -> Senha do servidor (use N/A para deixar sem senha)
  * TMOD_AUTOSAVE_INTERVAL=10      -> Salvamento automático do mundo em memória (em minutos)
  * BACKUP_INTERVAL_MINUTES=180    -> Intervalo para gerar arquivo .zip em Backups/ (em minutos)
  * BACKUP_KEEP_COUNT=10           -> Quantidade máxima de backups .zip mantidos na pasta Backups/
  * DISCORD_WEBHOOK_URL=           -> Link do Webhook do Discord (ou configure no arquivo .env)

Como criar e configurar o Webhook no Discord:
  1. No Discord, clique na Engrenagem (Editar Canal) ao lado do canal de texto desejado.
  2. Vá em "Integrações" -> "Webhooks" -> "Novo Webhook".
  3. Clique em "Copiar URL do Webhook".
  4. Cole no arquivo ".env" na raiz da pasta (protegido pelo .gitignore):
     DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...


7. RESILIÊNCIA, BACKUPS E SOLUÇÃO DE PROBLEMAS (TROUBLESHOOTING)
--------------------------------------------------------------------------------
* Como restaurar um backup se algo der errado no mundo?
  - Automático: Se o arquivo ".wld" ou ".twld" corromper (por queda de luz, por
    exemplo), o servidor detecta a falha ao ligar e restaura sozinho o último
    backup íntegro da pasta "Backups/".
  - Manual: Abra o "PainelMenu.bat", escolha a opção [4] e selecione na lista
    qual dos 10 backups você deseja restaurar.

* O servidor falhou ao iniciar após adicionar novos mods (Modo Seguro):
  - Se um mod incompatível impedir o servidor de abrir por 3 tentativas seguidas,
    o Modo Seguro identificará o mod culpado no log, gravará os detalhes em
    "Logs/diagnostico_mods.txt" (visível também na opção [5] do PainelMenu.bat)
    e desativará temporariamente apenas o mod problemático para o servidor subir.
  - Assim que você editar o arquivo "Mods/install.txt", o isolamento do Modo
    Seguro é limpo automaticamente.

* Nota Técnica Importante (.NET 8 / libicu-dev):
  - Nunca adicione "DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1" no docker-compose.yml,
    pois o Terraria exige suporte a culturas ("en-US") ao iniciar. O suporte
    correto já está configurado nativamente no "Dockerfile" através do pacote
    "libicu-dev".
================================================================================
