# ==============================================================================
# Gerenciador Completo do Servidor Terraria (tModLoader Docker) para Windows
# ==============================================================================
param(
    [ValidateSet("Start", "Stop", "Menu", "Backup", "Restore", "Logs", "Command", "Test", "Uninstall")]
    [string]$Action = "Menu"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$RootDir = Split-Path -Parent $PSScriptRoot
Set-Location $RootDir

function Write-Header($Title) {
    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor White
    Write-Host "==================================================================" -ForegroundColor Cyan
}

function Get-RadminIP {
    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -like "26.*" -or $_.InterfaceAlias -match "Radmin" } |
            Select-Object -ExpandProperty IPAddress -First 1
        return $ip
    } catch {
        return $null
    }
}

function Update-EnvFile($RadminIP) {
    $envPath = Join-Path $RootDir ".env"
    $lines = @()
    if (Test-Path $envPath) {
        $lines = Get-Content $envPath -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch "^RADMIN_IP=" }
    }
    if ($RadminIP) {
        $lines += "RADMIN_IP=$RadminIP"
    } else {
        $lines += "RADMIN_IP="
    }
    Set-Content -Path $envPath -Value $lines -Encoding UTF8
}

function Ensure-FirewallRules {
    $ruleCheck = netsh advfirewall firewall show rule name="Terraria_tModLoader_7777_TCP" 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Regras do Firewall (Portas 7777 e 9443) ativas." -ForegroundColor Green
        return
    }

    Write-Host "[REDE] Configurando liberacao das portas 7777 (Jogo) e 9443 (Portainer) no Firewall do Windows..." -ForegroundColor Yellow
    $fwCmd = @"
netsh advfirewall firewall delete rule name="Terraria_tModLoader_7777_TCP" >nul 2>&1
netsh advfirewall firewall delete rule name="Terraria_tModLoader_7777_UDP" >nul 2>&1
netsh advfirewall firewall delete rule name="Terraria_Portainer_9443_TCP" >nul 2>&1
netsh advfirewall firewall add rule name="Terraria_tModLoader_7777_TCP" dir=in action=allow protocol=TCP localport=7777 remoteip=26.0.0.0/8 profile=any >nul
netsh advfirewall firewall add rule name="Terraria_tModLoader_7777_UDP" dir=in action=allow protocol=UDP localport=7777 remoteip=26.0.0.0/8 profile=any >nul
netsh advfirewall firewall add rule name="Terraria_Portainer_9443_TCP" dir=in action=allow protocol=TCP localport=9443 remoteip=26.0.0.0/8 profile=any >nul
"@
    try {
        $tempBat = Join-Path $env:TEMP "terraria_fw_setup.bat"
        Set-Content -Path $tempBat -Value $fwCmd -Encoding ASCII
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$tempBat`"" -Verb RunAs -WindowStyle Hidden -Wait
        Remove-Item $tempBat -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] Portas 7777 (TCP/UDP) e 9443 (TCP) liberadas no Firewall SOMENTE para a faixa do Radmin VPN (26.0.0.0/8)!" -ForegroundColor Green
    } catch {
        Write-Host "[AVISO] Nao foi possivel aplicar as regras de Firewall automaticamente (Permissao recusada)." -ForegroundColor Yellow
    }
}

function Ensure-RadminVPN {
    $radminPaths = @(
        "${env:ProgramFiles(x86)}\Radmin VPN\RvGui.exe",
        "${env:ProgramFiles}\Radmin VPN\RvGui.exe"
    )
    $radminExe = $radminPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $radminExe) {
        Write-Host "[DEPENDENCIA] Radmin VPN nao encontrado neste computador." -ForegroundColor Yellow
        $resp = Read-Host "Deseja instalar o Radmin VPN automaticamente agora? (S/N)"
        if ($resp -match "^[sS]") {
            Write-Host "Instalando Radmin VPN via Winget..." -ForegroundColor Cyan
            winget install -e --id Famatech.RadminVPN --accept-source-agreements --accept-package-agreements
            $radminExe = $radminPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
        }
    }

    if ($radminExe) {
        $svc = Get-Service -Name "RvControlSvc" -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne "Running") {
            Start-Service "RvControlSvc" -ErrorAction SilentlyContinue
        }
        $proc = Get-Process -Name "RvGui" -ErrorAction SilentlyContinue
        if (-not $proc) {
            Write-Host "[REDE] Iniciando aplicativo Radmin VPN..." -ForegroundColor Cyan
            Start-Process -FilePath $radminExe
            Start-Sleep -Seconds 3
        } else {
            Write-Host "[OK] Radmin VPN ja esta aberto." -ForegroundColor Green
        }
    }
}

function Ensure-DockerEngine {
    $dockerExe = "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe"
    $hasDockerCli = [bool](Get-Command "docker" -ErrorAction SilentlyContinue)

    if (-not $hasDockerCli -and -not (Test-Path $dockerExe)) {
        Write-Host "[DEPENDENCIA] Docker Desktop nao encontrado neste computador!" -ForegroundColor Yellow
        $resp = Read-Host "Deseja instalar o WSL2 e o Docker Desktop automaticamente agora? (S/N)"
        if ($resp -match "^[sS]") {
            Write-Host "Verificando/Instalando WSL2..." -ForegroundColor Cyan
            wsl --install --no-distribution 2>$null
            Write-Host "Instalando Docker Desktop via Winget..." -ForegroundColor Cyan
            winget install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
            Write-Host "[IMPORTANTE] Caso seja a primeira instalacao do Docker Desktop, pode ser necessario reiniciar o Windows." -ForegroundColor Yellow
        } else {
            Write-Host "[ERRO] O Docker Desktop e obrigatorio para rodar o servidor." -ForegroundColor Red
            exit 1
        }
    }

    docker info >$null 2>&1
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path $dockerExe) {
            Write-Host "[DOCKER] Iniciando o Docker Desktop..." -ForegroundColor Cyan
            Start-Process -FilePath $dockerExe
        }
        Write-Host "[DOCKER] Aguardando o motor do Docker iniciar (isso pode levar alguns segundos)..." -ForegroundColor Yellow
        $waited = 0
        while ($true) {
            Start-Sleep -Seconds 2
            $waited += 2
            docker info >$null 2>&1
            if ($LASTEXITCODE -eq 0) {
                break
            }
            Write-Host "." -NoNewline -ForegroundColor DarkGray
            if ($waited -ge 180) {
                Write-Host ""
                Write-Host "[ERRO] Tempo limite aguardando o Docker Desktop iniciar. Verifique se o Docker Desktop abriu corretamente." -ForegroundColor Red
                exit 1
            }
        }
        Write-Host ""
    }
    Write-Host "[OK] Motor do Docker ativo e pronto!" -ForegroundColor Green
}

function Start-TerrariaServer {
    Write-Header "INICIANDO SERVIDOR DEDICADO TERRARIA (tModLoader)"

    Ensure-RadminVPN
    Ensure-FirewallRules
    $radminIP = Get-RadminIP
    if ($radminIP) {
        Write-Host "[OK] IP Radmin VPN detectado: $radminIP" -ForegroundColor Green
    } else {
        Write-Host "[AVISO] IP do Radmin VPN ainda nao detectado (conecte-se a uma rede no Radmin VPN)." -ForegroundColor Yellow
    }
    Update-EnvFile $radminIP

    Ensure-DockerEngine

    Write-Host ""
    Write-Host "[SERVIDOR] Construindo/atualizando imagem e iniciando containers..." -ForegroundColor Cyan
    $startTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    docker-compose up -d --build
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERRO] Falha ao executar docker-compose up -d --build." -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor DarkCyan
    Write-Host " Acompanhando inicializacao do mundo e download de mods..." -ForegroundColor Cyan
    Write-Host " (O painel avisara assim que o servidor estiver ONLINE!)" -ForegroundColor Gray
    Write-Host "==================================================================" -ForegroundColor DarkCyan

    $lastLineCount = 0
    $onlineReached = $false
    $waitSeconds = 0

    while (-not $onlineReached -and $waitSeconds -lt 600) {
        Start-Sleep -Seconds 2
        $waitSeconds += 2

        $logs = docker logs --since $startTime servidor_tmodloader 2>&1
        if ($logs) {
            $lines = @($logs)
            if ($lines.Count -gt $lastLineCount) {
                for ($i = $lastLineCount; $i -lt $lines.Count; $i++) {
                    $line = $lines[$i].ToString()
                    if ($line -match "SERVIDOR ONLINE E PRONTO|Listening on port|Server started") {
                        Write-Host $line -ForegroundColor Green
                        $onlineReached = $true
                    } elseif ($line -match "\[MODS\]|\[BACKUP\]") {
                        Write-Host $line -ForegroundColor Cyan
                    } elseif ($line -match "WARN|ERROR|Exception|WATCHDOG") {
                        Write-Host $line -ForegroundColor Yellow
                    } else {
                        Write-Host $line -ForegroundColor Gray
                    }
                }
                $lastLineCount = $lines.Count
            }
        }
    }

    $radminIP = Get-RadminIP
    Write-Host ""
    if ($onlineReached) {
        Write-Host "==================================================================" -ForegroundColor Green
        Write-Host " [ONLINE] SERVIDOR TERRARIA PRONTO PARA JOGAR!" -ForegroundColor Green
        Write-Host "==================================================================" -ForegroundColor Green
        if ($radminIP) {
            Write-Host " -> IP para Amigos (Radmin VPN) : ${radminIP}:7777" -ForegroundColor White
            Write-Host " -> Painel Portainer na Rede    : https://${radminIP}:9443" -ForegroundColor Gray
        } else {
            Write-Host " -> IP para Amigos (Radmin VPN) : (Abra o Radmin VPN e copie seu IP 26.x.x.x):7777" -ForegroundColor Yellow
        }
        Write-Host " -> IP Local (Para voce no PC)  : 127.0.0.1:7777" -ForegroundColor White
        Write-Host " -> Painel Web Local (Portainer): https://localhost:9443" -ForegroundColor Gray
        Write-Host "==================================================================" -ForegroundColor Green
    } else {
        Write-Host "[AVISO] O servidor ainda esta carregando em segundo plano ou encontrou um erro. Verifique os logs." -ForegroundColor Yellow
    }
}

function Stop-TerrariaServer {
    Write-Header "DESLIGANDO SERVIDOR COM SEGURANCA (SAVE + BACKUP)"
    Write-Host "Enviando comando de salvamento (save e exit) ao Terraria e gerando backup .zip..." -ForegroundColor Yellow
    docker-compose stop -t 45 tmodloader

    $latestBackup = Get-ChildItem -Path (Join-Path $RootDir "Backups") -Filter "backup_*.zip" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    Write-Host ""
    Write-Host "[OK] Servidor desligado e mundo salvo com seguranca!" -ForegroundColor Green
    if ($latestBackup) {
        $sizeMB = [math]::Round($latestBackup.Length / 1MB, 2)
        Write-Host "[BACKUP] Ultimo Backup salvo em Backups/: $($latestBackup.Name) ($sizeMB MB)" -ForegroundColor Cyan
    }
}

function Invoke-ManualBackup {
    Write-Header "FORCAR BACKUP DO MUNDO AGORA"
    $running = docker ps -q -f name=servidor_tmodloader 2>$null
    if ($running) {
        Write-Host "Salvando o mundo em memoria no Terraria..." -ForegroundColor Cyan
        docker exec servidor_tmodloader inject "save" 2>$null
        Start-Sleep -Seconds 3
        docker exec servidor_tmodloader /terraria-server/scripts/backup_manager.sh create manual
    } else {
        Write-Host "Servidor desligado. Compactando arquivos da pasta Worlds/ diretamente..." -ForegroundColor Cyan
        $worldsDir = Join-Path $RootDir "Worlds"
        $backupsDir = Join-Path $RootDir "Backups"
        New-Item -ItemType Directory -Path $backupsDir -Force | Out-Null
        $wldFiles = Get-ChildItem -Path $worldsDir -Filter "*.wld" -ErrorAction SilentlyContinue
        if (-not $wldFiles) {
            Write-Host "[AVISO] Nenhum arquivo .wld encontrado na pasta Worlds/." -ForegroundColor Yellow
            return
        }
        $ts = (Get-Date).ToString("yyyy-MM-dd_HH-mm-ss")
        $worldBase = $wldFiles[0].BaseName
        $zipPath = Join-Path $backupsDir "backup_${worldBase}_${ts}_manual.zip"
        $toCompress = Get-ChildItem -Path $worldsDir -Include "${worldBase}.wld", "${worldBase}.twld" -File
        Compress-Archive -Path $toCompress.FullName -DestinationPath $zipPath -Force
        Write-Host "[OK] Backup criado: $(Split-Path $zipPath -Leaf)" -ForegroundColor Green
    }
}

function Invoke-RestoreBackup {
    Write-Header "RESTAURAR UM BACKUP DA PASTA BACKUPS/"
    $backupsDir = Join-Path $RootDir "Backups"
    $backups = @(Get-ChildItem -Path $backupsDir -Filter "backup_*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)

    if ($backups.Count -eq 0) {
        Write-Host "[AVISO] Nenhum backup .zip encontrado na pasta Backups/." -ForegroundColor Yellow
        return
    }

    Write-Host "Backups disponiveis (do mais recente para o mais antigo):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $backups.Count; $i++) {
        $b = $backups[$i]
        $sizeMB = [math]::Round($b.Length / 1MB, 2)
        $dateStr = $b.LastWriteTime.ToString("dd/MM/yyyy HH:mm:ss")
        Write-Host ("  [{0}] {1}  ({2} MB - {3})" -f ($i + 1), $b.Name, $sizeMB, $dateStr) -ForegroundColor White
    }
    Write-Host "  [0] Cancelar" -ForegroundColor Gray
    Write-Host ""

    $choice = Read-Host "Digite o numero do backup que deseja restaurar"
    if (-not ($choice -match "^\d+$")) { return }
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $backups.Count) { return }

    $selectedZip = $backups[$idx]
    $confirm = Read-Host "Tem certeza que deseja substituir o mundo atual por '$($selectedZip.Name)'? (S/N)"
    if ($confirm -notmatch "^[sS]") {
        Write-Host "Restauracao cancelada." -ForegroundColor Gray
        return
    }

    $running = docker ps -q -f name=servidor_tmodloader 2>$null
    if ($running) {
        Write-Host "Parando o servidor temporariamente para restaurar os arquivos do mundo..." -ForegroundColor Yellow
        docker kill servidor_tmodloader >$null 2>&1
        Start-Sleep -Seconds 2
    }

    $worldsDir = Join-Path $RootDir "Worlds"
    Expand-Archive -Path $selectedZip.FullName -DestinationPath $worldsDir -Force
    Write-Host "[OK] Backup '$($selectedZip.Name)' restaurado com sucesso na pasta Worlds/!" -ForegroundColor Green

    if ($running) {
        Write-Host "Reiniciando o servidor com o backup restaurado..." -ForegroundColor Cyan
        docker start servidor_tmodloader >$null 2>&1
        Write-Host "[OK] Servidor reiniciado!" -ForegroundColor Green
    }
}

function Uninstall-TerrariaEnvironment {
    Write-Header "REVERTER CONFIGURACOES FEITAS PELO APP NESTE PC"
    Write-Host "Isto remove: regras de Firewall, containers, volume do Portainer e imagens deste projeto." -ForegroundColor Yellow
    Write-Host "Seus mundos, backups, mods e arquivos do projeto NAO sao apagados." -ForegroundColor Gray
    $confirm = Read-Host "Deseja continuar? (S/N)"
    if ($confirm -notmatch "^[sS]") { return }

    if ([bool](Get-Command "docker" -ErrorAction SilentlyContinue)) {
        docker info >$null 2>&1
        if ($LASTEXITCODE -eq 0) {
            docker-compose down --volumes --rmi local
            docker rmi jacobsmile/tmodloader1.4:latest portainer/portainer-ce:latest 2>$null
        }
    }

    $fwCmd = 'Remove-NetFirewallRule -DisplayName "Terraria_tModLoader_7777_TCP","Terraria_tModLoader_7777_UDP","Terraria_Portainer_9443_TCP" -ErrorAction SilentlyContinue'
    Start-Process -FilePath powershell.exe -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList "-NoProfile", "-Command", $fwCmd
    $left = @(Get-NetFirewallRule -DisplayName "Terraria_*" -ErrorAction SilentlyContinue).Count
    if ($left -eq 0) {
        Write-Host "[OK] Regras de Firewall removidas." -ForegroundColor Green
    } else {
        Write-Host "[AVISO] $left regra(s) de Firewall ainda existem (permissao de administrador recusada?)." -ForegroundColor Yellow
    }
    Update-EnvFile $null
    Write-Host "[OK] Ambiente revertido. Docker Desktop e Radmin VPN nao foram desinstalados." -ForegroundColor Green
}

function Show-LogsAndDiagnostics {
    Write-Header "LOGS AO VIVO E DIAGNOSTICO DE MODS"
    $diagFile = Join-Path $RootDir "Logs\diagnostico_mods.txt"
    if (Test-Path $diagFile) {
        Write-Host "[ALERTA] ULTIMO DIAGNOSTICO DE FALHA DE MODS REGISTRADO:" -ForegroundColor Yellow
        Get-Content $diagFile | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        Write-Host ""
    }
    Write-Host "Exibindo logs do servidor em tempo real (Pressione CTRL+C para voltar)..." -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
    docker logs -f --tail 60 servidor_tmodloader
}

function Send-TerrariaCommand {
    Write-Header "ENVIAR COMANDO PARA O CONSOLE DO TERRARIA"
    $running = docker ps -q -f name=servidor_tmodloader 2>$null
    if (-not $running) {
        Write-Host "[AVISO] O servidor nao esta rodando no momento." -ForegroundColor Yellow
        return
    }

    Write-Host "Exemplos de comandos uteis:" -ForegroundColor Cyan
    Write-Host "  say Ola pessoal!   -> Envia mensagem no chat do jogo" -ForegroundColor Gray
    Write-Host "  save               -> Salva o mundo imediatamente" -ForegroundColor Gray
    Write-Host "  playing            -> Lista os jogadores online" -ForegroundColor Gray
    Write-Host "  dawn / noon / dusk -> Muda o horario do dia (amanhecer / meio-dia / noite)" -ForegroundColor Gray
    Write-Host "  kick NomeJogador   -> Expulsa um jogador" -ForegroundColor Gray
    Write-Host ""
    $cmd = Read-Host "Digite o comando para enviar (ou Enter para cancelar)"
    if ([string]::IsNullOrWhiteSpace($cmd)) { return }

    docker exec servidor_tmodloader inject "$cmd"
    Write-Host "[OK] Comando '$cmd' enviado! Resposta recente do console:" -ForegroundColor Green
    Start-Sleep -Seconds 2
    docker logs --tail 10 servidor_tmodloader
}

function Show-InteractiveMenu {
    while ($true) {
        Clear-Host
        $running = [bool](docker ps -q -f name=servidor_tmodloader 2>$null)
        $statusText = if ($running) { "[ONLINE]" } else { "[OFFLINE]" }
        $radminIP = Get-RadminIP
        $radminText = if ($radminIP) { "${radminIP}:7777" } else { "Nao detectado" }
        $backupsCount = @(Get-ChildItem -Path (Join-Path $RootDir "Backups") -Filter "backup_*.zip" -ErrorAction SilentlyContinue).Count

        Write-Host "==================================================================" -ForegroundColor Cyan
        Write-Host "         PAINEL DE CONTROLE - SERVIDOR TERRARIA (tModLoader)      " -ForegroundColor White
        Write-Host "==================================================================" -ForegroundColor Cyan
        Write-Host "  Status do Servidor : $statusText"
        Write-Host "  IP Radmin VPN      : $radminText"
        Write-Host "  Backups Salvos     : $backupsCount / 10 (na pasta Backups/)"
        Write-Host "==================================================================" -ForegroundColor Cyan
        Write-Host "  [1] Iniciar / Atualizar Servidor" -ForegroundColor Green
        Write-Host "  [2] Desligar Servidor com Seguranca (Salva Mundo + Backup)" -ForegroundColor Red
        Write-Host "  [3] Forcar Backup do Mundo Agora (.zip)" -ForegroundColor Cyan
        Write-Host "  [4] Restaurar um Backup Antigo (Escolher da lista)" -ForegroundColor Yellow
        Write-Host "  [5] Ver Logs ao Vivo / Diagnostico de Mods" -ForegroundColor White
        Write-Host "  [6] Enviar Comando para o Console do Terraria (say, save, noon...)" -ForegroundColor Magenta
        Write-Host "  [7] Abrir Painel Web (Portainer - Porta 9443)" -ForegroundColor Blue
        Write-Host "  [8] Executar Bateria de Testes Automatizados (12 Testes)" -ForegroundColor DarkCyan
        Write-Host "  [9] Reverter configuracoes do app neste PC (Firewall, containers, imagens)" -ForegroundColor DarkYellow
        Write-Host "  [0] Sair" -ForegroundColor Gray
        Write-Host "==================================================================" -ForegroundColor Cyan

        $opt = Read-Host "Escolha uma opcao"
        switch ($opt) {
            "1" { Start-TerrariaServer; Pause }
            "2" { Stop-TerrariaServer; Pause }
            "3" { Invoke-ManualBackup; Pause }
            "4" { Invoke-RestoreBackup; Pause }
            "5" { Show-LogsAndDiagnostics; Pause }
            "6" { Send-TerrariaCommand; Pause }
            "7" { Start-Process "https://localhost:9443" }
            "8" { & (Join-Path $PSScriptRoot "testar_servidor.ps1"); Pause }
            "9" { Uninstall-TerrariaEnvironment; Pause }
            "0" { return }
            default { }
        }
    }
}

switch ($Action) {
    "Start"   { Start-TerrariaServer }
    "Stop"    { Stop-TerrariaServer }
    "Backup"  { Invoke-ManualBackup }
    "Restore" { Invoke-RestoreBackup }
    "Logs"    { Show-LogsAndDiagnostics }
    "Command" { Send-TerrariaCommand }
    "Test"    { & (Join-Path $PSScriptRoot "testar_servidor.ps1") }
    "Uninstall" { Uninstall-TerrariaEnvironment }
    "Menu"    { Show-InteractiveMenu }
}
