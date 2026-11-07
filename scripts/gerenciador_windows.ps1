# ==============================================================================
# Gerenciador Completo do Servidor Terraria (tModLoader Docker) para Windows
# ==============================================================================
param(
    [ValidateSet("Start", "Stop", "Menu", "Backup", "Restore", "Logs", "Command", "Test", "Uninstall", "Network", "Update", "Progression")]
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

function Get-EnvValue([string]$Key, [string]$Default = "") {
    $envPath = Join-Path $RootDir ".env"
    if (Test-Path $envPath) {
        $line = Get-Content $envPath -ErrorAction SilentlyContinue |
            Where-Object { $_ -match "^$([regex]::Escape($Key))=(.*)$" } |
            Select-Object -First 1
        if ($line -match "^$([regex]::Escape($Key))=(.*)$") {
            $val = $Matches[1].Trim()
            if (-not [string]::IsNullOrWhiteSpace($val)) {
                return $val
            }
        }
    }
    return $Default
}

function Set-EnvValue([string]$Key, [string]$Value) {
    $envPath = Join-Path $RootDir ".env"
    $examplePath = Join-Path $RootDir ".env.example"
    if (-not (Test-Path $envPath) -and (Test-Path $examplePath)) {
        Copy-Item $examplePath $envPath -Force
    }
    $lines = @()
    $found = $false
    if (Test-Path $envPath) {
        $existingLines = Get-Content $envPath -ErrorAction SilentlyContinue
        foreach ($line in $existingLines) {
            if ($line -match "^$([regex]::Escape($Key))=") {
                $lines += "$Key=$Value"
                $found = $true
            } else {
                $lines += $line
            }
        }
    }
    if (-not $found) {
        $lines += "$Key=$Value"
    }
    # UTF-8 SEM BOM (o Set-Content -Encoding UTF8 do PowerShell 5.1 grava BOM, que pode
    # fazer o docker-compose ignorar a variavel da primeira linha do .env).
    [System.IO.File]::WriteAllLines($envPath, [string[]]$lines)
}

function Update-EnvFile($Provider, $RadminIP, $TailscaleIP) {
    if ($Provider) { Set-EnvValue "NETWORK_PROVIDER" $Provider }
    Set-EnvValue "RADMIN_IP" (if ($RadminIP) { $RadminIP } else { "" })
    Set-EnvValue "TAILSCALE_IP" (if ($TailscaleIP) { $TailscaleIP } else { "" })
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

function Test-IsContainerRunning([string]$ContainerName) {
    $dockerProc = Get-Process -Name "com.docker.backend", "Docker Desktop", "dockerd" -ErrorAction SilentlyContinue
    if (-not $dockerProc) {
        return $false
    }
    return [bool](docker ps -q -f name=$ContainerName 2>$null)
}

function Get-TailscaleIP {
    try {
        if (-not (Test-IsContainerRunning "vpn_tailscale") -and -not (Test-IsContainerRunning "servidor_tmodloader")) {
            return $null
        }
        $running = docker ps -q -f name=vpn_tailscale 2>$null
        if ($running) {
            $cliIp = docker exec vpn_tailscale tailscale ip -4 2>$null | Select-Object -First 1
            if ($cliIp -and $cliIp.Trim() -match "^100\.") {
                return $cliIp.Trim()
            }
        }
        $tmodRunning = docker ps -q -f name=servidor_tmodloader 2>$null
        if ($tmodRunning) {
            $ips = docker exec servidor_tmodloader hostname -I 2>$null
            if ($ips) {
                foreach ($token in ($ips -split "\s+")) {
                    if ($token -match "^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.") {
                        return $token.Trim()
                    }
                }
            }
        }
        # Sem fallback para o valor salvo no .env: um IP antigo nao prova que o container
        # esta autenticado. Se nao ha IP ativo, o Tailscale nao esta conectado.
        return $null
    } catch {
        return $null
    }
}

function Configure-TailscaleAuthKey {
    $currentKey = Get-EnvValue "TS_AUTHKEY" ""
    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Yellow
    Write-Host "  CONFIGURACAO DO TAILSCALE VPN (CONTAINER DOCKER)" -ForegroundColor White
    Write-Host "==================================================================" -ForegroundColor Yellow
    Write-Host "O Tailscale conecta o servidor a uma rede mesh privada (IP 100.x.y.z)." -ForegroundColor Cyan
    Write-Host "Voce tem duas formas de autenticar:" -ForegroundColor White
    Write-Host "  [Opcao A - Recomendado] Informar uma Auth Key (Login 100% automatico e silencioso):" -ForegroundColor White
    Write-Host "    1. Acesse: https://login.tailscale.com/admin/settings/keys" -ForegroundColor DarkGray
    Write-Host "    2. Clique em 'Generate auth key' (marque Reusable se quiser reutilizar) e copie a chave (tskey-auth-...)" -ForegroundColor DarkGray
    Write-Host "  [Opcao B - Interativo] Deixar em branco para login via Navegador:" -ForegroundColor White
    Write-Host "    Ao iniciar o servidor, o navegador sera aberto com o link de login da Tailscale." -ForegroundColor DarkGray
    Write-Host ""

    if ($currentKey) {
        $maskedKey = if ($currentKey.Length -gt 15) { $currentKey.Substring(0, 10) + "..." + $currentKey.Substring($currentKey.Length - 4) } else { "******" }
        Write-Host "Chave TS_AUTHKEY atual no .env: $maskedKey" -ForegroundColor Cyan
        $resp = Read-Host "Deseja alterar a chave TS_AUTHKEY? (S/N) (Padrao: N)"
        if ($resp -notmatch "^[sS]") {
            return
        }
    }

    $newKey = Read-Host "Cole sua Auth Key (tskey-auth-...) ou pressione [Enter] para autorizar via navegador"
    if (-not [string]::IsNullOrWhiteSpace($newKey)) {
        Set-EnvValue "TS_AUTHKEY" $newKey.Trim()
        Write-Host "[OK] Chave TS_AUTHKEY salva no arquivo .env!" -ForegroundColor Green
    } else {
        Set-EnvValue "TS_AUTHKEY" ""
        Write-Host "[INFO] TS_AUTHKEY deixada em branco. O link de login sera aberto ao iniciar o servidor." -ForegroundColor Gray
    }
}

function Select-NetworkProvider([bool]$ForceInteractive = $false) {
    $savedProvider = (Get-EnvValue "NETWORK_PROVIDER" "").ToLower()
    $validProviders = @("radmin", "tailscale", "hybrid", "local")

    if (-not $ForceInteractive -and ($validProviders -contains $savedProvider)) {
        Write-Host ""
        Write-Host "[AMBIENTE] Modo de Rede atual: $($savedProvider.ToUpper())" -ForegroundColor Cyan
        Write-Host "  (Pressione [C] em ate 4 segundos para trocar o provedor de VPN, ou aguarde para continuar...)" -ForegroundColor DarkGray
        $changeRequested = $false
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 4000) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::C) {
                    $changeRequested = $true
                    break
                } elseif ($key.Key -eq [ConsoleKey]::Enter -or $key.Key -eq [ConsoleKey]::Spacebar) {
                    break
                }
            }
            Start-Sleep -Milliseconds 100
        }
        if (-not $changeRequested) {
            return $savedProvider
        }
    }

    Write-Header "SELECAO DE REDE E DEPENDENCIAS DO AMBIENTE"
    Write-Host "Escolha como seus amigos vao se conectar ao servidor:" -ForegroundColor Cyan
    Write-Host "  [1] Radmin VPN           (App no Windows - salas com nome e senha, faixa 26.x.x.x)" -ForegroundColor White
    Write-Host "  [2] Tailscale Container  (100% no Docker Compose - sem instalar VPN no Windows, faixa 100.x.x.x)" -ForegroundColor Green
    Write-Host "  [3] Hibrido (Ambos)      (Alta Disponibilidade - Radmin + Container Tailscale simultaneos)" -ForegroundColor Yellow
    Write-Host "  [4] Apenas Rede Local    (Sem VPN - para LAN ou Port Forwarding direto no roteador)" -ForegroundColor Gray
    Write-Host ""

    $defaultOpt = switch ($savedProvider) {
        "tailscale" { "2" }
        "hybrid"    { "3" }
        "local"     { "4" }
        default     { "1" }
    }

    $choice = Read-Host "Digite a opcao desejada [1-4] (Padrao: $defaultOpt)"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = $defaultOpt }

    $selected = switch ($choice.Trim()) {
        "1" { "radmin" }
        "2" { "tailscale" }
        "3" { "hybrid" }
        "4" { "local" }
        default { "radmin" }
    }

    if ($selected -eq "tailscale" -or $selected -eq "hybrid") {
        Configure-TailscaleAuthKey
    }

    Update-EnvFile $selected (Get-RadminIP) (Get-TailscaleIP)
    Write-Host "[OK] Modo de rede definido como '$($selected.ToUpper())' e salvo no arquivo .env!" -ForegroundColor Green
    return $selected
}

function Ensure-FirewallRules([string]$Provider = "radmin") {
    $prov = $Provider.ToLower()
    $needsTsFw = ($prov -eq "tailscale" -or $prov -eq "hybrid")
    $needsTerrariaFw = ($prov -eq "radmin" -or $prov -eq "hybrid" -or $prov -eq "local" -or $prov -eq "tailscale")

    $commandsToRun = @()

    # 1. Regra para conexoes diretas P2P do Tailscale WireGuard (Porta 41641/UDP)
    if ($needsTsFw) {
        $tsRuleCheck = netsh advfirewall firewall show rule name="Terraria_Tailscale_41641_UDP" verbose 2>$null | Out-String
        if ($LASTEXITCODE -ne 0 -or -not ($tsRuleCheck -match "41641")) {
            Write-Host "[FIREWALL] Liberando porta 41641 (UDP) para conexoes diretas P2P do Tailscale WireGuard..." -ForegroundColor Yellow
            $commandsToRun += 'netsh advfirewall firewall delete rule name="Terraria_Tailscale_41641_UDP" >nul 2>&1'
            $commandsToRun += 'netsh advfirewall firewall add rule name="Terraria_Tailscale_41641_UDP" dir=in action=allow protocol=UDP localport=41641 profile=any >nul'
        } else {
            Write-Host "[OK] Regra do Firewall para Tailscale (Porta 41641 UDP P2P) ativa." -ForegroundColor Green
        }
    }

    # 2. Regras para Terraria (7777 TCP/UDP) e Portainer (9443 TCP)
    if ($needsTerrariaFw) {
        $remoteIps = switch ($prov) {
            "hybrid"    { "26.0.0.0/8,LocalSubnet" }
            "radmin"    { "26.0.0.0/8,LocalSubnet" }
            default     { "LocalSubnet" }
        }

        $ruleCheck = netsh advfirewall firewall show rule name="Terraria_tModLoader_7777_TCP" verbose 2>$null | Out-String
        $needsUpdate = $false
        if ($LASTEXITCODE -ne 0) {
            $needsUpdate = $true
        } elseif (($prov -eq "radmin" -or $prov -eq "hybrid") -and ($ruleCheck -notmatch "26\.0\.0\.0")) {
            $needsUpdate = $true
        } elseif (($prov -eq "local" -or $prov -eq "tailscale") -and ($ruleCheck -notmatch "LocalSubnet")) {
            $needsUpdate = $true
        }

        if ($needsUpdate) {
            Write-Host "[FIREWALL] Configurando liberacao das portas 7777 (Jogo) e 9443 (Portainer) no Firewall ($remoteIps)..." -ForegroundColor Yellow
            $commandsToRun += 'netsh advfirewall firewall delete rule name="Terraria_tModLoader_7777_TCP" >nul 2>&1'
            $commandsToRun += 'netsh advfirewall firewall delete rule name="Terraria_tModLoader_7777_UDP" >nul 2>&1'
            $commandsToRun += 'netsh advfirewall firewall delete rule name="Terraria_Portainer_9443_TCP" >nul 2>&1'
            $commandsToRun += "netsh advfirewall firewall add rule name=`"Terraria_tModLoader_7777_TCP`" dir=in action=allow protocol=TCP localport=7777 remoteip=$remoteIps profile=any >nul"
            $commandsToRun += "netsh advfirewall firewall add rule name=`"Terraria_tModLoader_7777_UDP`" dir=in action=allow protocol=UDP localport=7777 remoteip=$remoteIps profile=any >nul"
            $commandsToRun += "netsh advfirewall firewall add rule name=`"Terraria_Portainer_9443_TCP`" dir=in action=allow protocol=TCP localport=9443 remoteip=$remoteIps profile=any >nul"
        } else {
            Write-Host "[OK] Regras do Firewall (Portas 7777 e 9443) ativas para '$Provider'." -ForegroundColor Green
        }
    }

    if ($commandsToRun.Count -gt 0) {
        try {
            $tempBat = Join-Path $env:TEMP "terraria_fw_setup.bat"
            Set-Content -Path $tempBat -Value ($commandsToRun -join "`r`n") -Encoding ASCII
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$tempBat`"" -Verb RunAs -WindowStyle Hidden -Wait
            Remove-Item $tempBat -Force -ErrorAction SilentlyContinue
            Write-Host "[OK] Regras de Firewall atualizadas com sucesso!" -ForegroundColor Green
        } catch {
            Write-Host "[AVISO] Nao foi possivel aplicar as regras de Firewall automaticamente (Permissao recusada)." -ForegroundColor Yellow
        }
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
        return $true
    }
    return $false
}

function Ensure-TailscaleContainer {
    Write-Host "[TAILSCALE] Verificando container 'vpn_tailscale' no Docker..." -ForegroundColor Cyan

    $running = docker ps -q -f name=vpn_tailscale 2>$null
    if (-not $running) {
        Write-Host "[TAILSCALE] Container 'vpn_tailscale' nao esta em execucao. Subindo container..." -ForegroundColor Cyan
        docker-compose up -d tailscale 2>$null
        Start-Sleep -Seconds 3
    }

    $tsIp = Get-TailscaleIP
    if ($tsIp -and $tsIp -match "^100\.") {
        Write-Host "[OK] Container Tailscale conectado! IP da rede Mesh: $tsIp" -ForegroundColor Green
        return $tsIp
    }

    $hostnameVal = Get-EnvValue "TS_HOSTNAME" "terraria-tmodloader"
    $authKey = Get-EnvValue "TS_AUTHKEY" ""

    if ($authKey) {
        Write-Host "[TAILSCALE] Autenticando via TS_AUTHKEY configurada no .env..." -ForegroundColor Cyan
        $null = docker exec vpn_tailscale tailscale up --hostname=$hostnameVal --authkey=$authKey --accept-dns=false 2>&1
    } else {
        Write-Host ""
        Write-Host "==================================================================" -ForegroundColor Yellow
        Write-Host "  AUTENTICACAO DO TAILSCALE VPN (CONTA NECESSARIA)" -ForegroundColor White
        Write-Host "==================================================================" -ForegroundColor Yellow
        Write-Host "O container Tailscale precisa ser conectado a sua conta Tailscale." -ForegroundColor Cyan
        Write-Host "Dica: Para login silencioso automatico, gere uma Auth Key em:" -ForegroundColor Gray
        Write-Host "-> https://login.tailscale.com/admin/settings/keys" -ForegroundColor DarkCyan
        Write-Host ""
        $inputKey = Read-Host "Cole sua Auth Key (tskey-auth-...) ou pressione [Enter] para autorizar via Navegador"
        if (-not [string]::IsNullOrWhiteSpace($inputKey)) {
            $authKey = $inputKey.Trim()
            Set-EnvValue "TS_AUTHKEY" $authKey
            Write-Host "[OK] Chave TS_AUTHKEY salva no .env! Conectando..." -ForegroundColor Green
            $null = docker exec vpn_tailscale tailscale up --hostname=$hostnameVal --authkey=$authKey --accept-dns=false 2>&1
        } else {
            Write-Host "[TAILSCALE] Obtendo link de autorizacao do Tailscale..." -ForegroundColor Yellow
            Start-Sleep -Seconds 2

            $loginUrl = $null
            # 1. Tenta capturar dos logs do container
            $cLogs = docker logs --tail 40 vpn_tailscale 2>&1 | Out-String
            if ($cLogs -match "(https://login\.tailscale\.com/(?:a|register)/[a-zA-Z0-9_]+)") {
                $loginUrl = $Matches[1]
            }

            # 2. Se nao encontrou nos logs, tenta via 'tailscale up'
            if (-not $loginUrl) {
                $upOut = docker exec vpn_tailscale tailscale up --hostname=$hostnameVal --accept-dns=false --timeout=8s 2>&1 | Out-String
                if ($upOut -match "(https://login\.tailscale\.com/(?:a|register)/[a-zA-Z0-9_]+)") {
                    $loginUrl = $Matches[1]
                }
            }

            # 3. Se ainda nao encontrou, tenta 'tailscale login'
            if (-not $loginUrl) {
                $loginOut = docker exec vpn_tailscale tailscale login --hostname=$hostnameVal --accept-dns=false 2>&1 | Out-String
                if ($loginOut -match "(https://login\.tailscale\.com/(?:a|register)/[a-zA-Z0-9_]+)") {
                    $loginUrl = $Matches[1]
                }
            }

            if ($loginUrl) {
                Write-Host ""
                Write-Host "==================================================================" -ForegroundColor Yellow
                Write-Host " [ACAO UNICA] AUTORIZE O SERVIDOR NO SEU NAVEGADOR:" -ForegroundColor Yellow
                Write-Host " -> Link: $loginUrl" -ForegroundColor Cyan
                Write-Host " (Abrindo navegador... Apos autorizar, o servidor continua sozinho!)" -ForegroundColor Gray
                Write-Host "==================================================================" -ForegroundColor Yellow
                Start-Process $loginUrl -ErrorAction SilentlyContinue
            } else {
                Write-Host "[AVISO] Nao foi possivel capturar o link automaticamente." -ForegroundColor Yellow
                Write-Host "        Verifique os logs executando: docker logs vpn_tailscale" -ForegroundColor DarkGray
            }
        }
    }

    Write-Host "[TAILSCALE] Aguardando conclusao da conexao (IP 100.x.y.z)..." -ForegroundColor Cyan
    for ($w = 0; $w -lt 45; $w++) {
        Start-Sleep -Seconds 2
        $tsIp = Get-TailscaleIP
        if ($tsIp -and $tsIp -match "^100\.") {
            Write-Host ""
            Write-Host "[OK] Container Tailscale autenticado com sucesso! IP: $tsIp" -ForegroundColor Green
            return $tsIp
        }
        Write-Host "." -NoNewline -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "[AVISO] Container Tailscale ainda nao obteve um IP 100.x.y.z a tempo." -ForegroundColor Yellow
    Write-Host "        Se autorizou pelo navegador, a conexao pode levar alguns instantes para sincronizar." -ForegroundColor Gray
    return $null
}

function Ensure-NetworkEnvironment {
    $provider = Select-NetworkProvider -ForceInteractive $false

    if ($provider -eq "radmin") {
        $ok = Ensure-RadminVPN
        $radminIP = Get-RadminIP
        if (-not $ok -or -not $radminIP) {
            Write-Host "[AVISO] Radmin VPN nao retornou um IP ativo (26.x.x.x)." -ForegroundColor Yellow
            $fb = Read-Host "Deseja ativar automaticamente o Container Tailscale (no Docker) como contingencia (Fallback)? (S/N)"
            if ($fb -match "^[sS]") {
                Write-Host "[FALLBACK] Ativando modo Hibrido (Radmin + Container Tailscale no Docker Compose)..." -ForegroundColor Cyan
                $provider = "hybrid"
            }
        }
    } elseif ($provider -eq "tailscale") {
        Write-Host "[REDE] Modo Tailscale Container selecionado (100% dentro do Docker Compose, zero instalacao no Windows)." -ForegroundColor Green
    } elseif ($provider -eq "hybrid") {
        Write-Host "[REDE] Modo Hibrido ativo: Radmin VPN (Host) + Tailscale (Container Docker)..." -ForegroundColor Cyan
        Ensure-RadminVPN | Out-Null
    } else {
        Write-Host "[REDE] Modo Rede Local / Direto selecionado (sem dependencia de VPN)." -ForegroundColor Gray
    }

    Ensure-FirewallRules -Provider $provider

    $radminIP = Get-RadminIP
    $tsIP = Get-TailscaleIP
    if ($radminIP) {
        Write-Host "[OK] IP Radmin VPN detectado: $radminIP" -ForegroundColor Green
    }

    Update-EnvFile $provider $radminIP $tsIP
    return $provider
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

    $activeProvider = Ensure-NetworkEnvironment
    Ensure-DockerEngine

    Write-Host ""
    Write-Host "[SERVIDOR] Construindo/atualizando imagem e iniciando containers (Modo: $($activeProvider.ToUpper()))..." -ForegroundColor Cyan
    $startTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    if ($activeProvider -eq "tailscale" -or $activeProvider -eq "hybrid") {
        docker-compose up -d --build tmodloader portainer tailscale
    } else {
        docker-compose stop tailscale 2>$null
        docker-compose up -d --build tmodloader portainer
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERRO] Falha ao executar docker-compose up -d --build." -ForegroundColor Red
        return
    }

    if ($activeProvider -eq "tailscale" -or $activeProvider -eq "hybrid") {
        $tsIp = Ensure-TailscaleContainer
        Update-EnvFile $activeProvider (Get-RadminIP) $tsIp
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
    $tsIP = Get-TailscaleIP
    Write-Host ""
    if ($onlineReached) {
        Write-Host "==================================================================" -ForegroundColor Green
        Write-Host " [ONLINE] SERVIDOR TERRARIA PRONTO PARA JOGAR! (Modo: $($activeProvider.ToUpper()))" -ForegroundColor Green
        Write-Host "==================================================================" -ForegroundColor Green
        if ($radminIP) {
            Write-Host " -> IP para Amigos (Radmin VPN)   : ${radminIP}:7777" -ForegroundColor White
            Write-Host " -> Painel Portainer (Radmin)     : https://${radminIP}:9443" -ForegroundColor Gray
        }
        if ($tsIP) {
            Write-Host " -> IP para Amigos (Tailscale VPN): ${tsIP}:7777" -ForegroundColor Cyan
            Write-Host " -> Painel Portainer (Tailscale)  : https://${tsIP}:9443" -ForegroundColor Gray
        }
        if (-not $radminIP -and -not $tsIP -and $activeProvider -ne "local") {
            Write-Host " -> AVISO VPN: Nenhuma VPN ativa (Radmin ou Tailscale). Amigos externos nao conseguirao conectar." -ForegroundColor Yellow
        }
        Write-Host " -> IP Local (Para voce no PC)    : 127.0.0.1:7777" -ForegroundColor White
        Write-Host " -> Painel Web Local (Portainer)  : https://localhost:9443" -ForegroundColor Gray
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
        $toCompress = Get-ChildItem -Path $worldsDir -Include "${worldBase}.wld", "${worldBase}.twld", "${worldBase}_progression.json" -File
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
            docker rmi jacobsmile/tmodloader1.4:latest portainer/portainer-ce:lts portainer/portainer-ce:latest tailscale/tailscale:stable tailscale/tailscale:latest 2>$null
        }
    }

    $fwCmd = 'Remove-NetFirewallRule -DisplayName "Terraria_tModLoader_7777_TCP","Terraria_tModLoader_7777_UDP","Terraria_Portainer_9443_TCP","Terraria_Tailscale_41641_UDP" -ErrorAction SilentlyContinue'
    Start-Process -FilePath powershell.exe -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList "-NoProfile", "-Command", $fwCmd
    $left = @(Get-NetFirewallRule -DisplayName "Terraria_*" -ErrorAction SilentlyContinue).Count
    if ($left -eq 0) {
        Write-Host "[OK] Regras de Firewall removidas." -ForegroundColor Green
    } else {
        Write-Host "[AVISO] $left regra(s) de Firewall ainda existem (permissao de administrador recusada?)." -ForegroundColor Yellow
    }
    Update-EnvFile "radmin" $null $null
    Set-EnvValue "TMOD_OFFICIAL_VERSION" ""
    Write-Host "[OK] Ambiente revertido. Docker Desktop, Radmin VPN e Tailscale nao foram desinstalados." -ForegroundColor Green
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

function Invoke-StandardImageUpdate {
    Write-Header "ATUALIZACAO PADRAO DAS IMAGENS (DOCKER HUB)"
    Write-Host "Esta operacao baixa as imagens mais recentes no Docker Hub:" -ForegroundColor Cyan
    Write-Host "  - tModLoader Server (jacobsmile/tmodloader1.4:latest)" -ForegroundColor White
    Write-Host "  - Tailscale VPN (tailscale/tailscale:stable)" -ForegroundColor White
    Write-Host "  - Portainer CE (portainer/portainer-ce:lts)" -ForegroundColor White
    Write-Host ""
    $currentOfficial = Get-EnvValue "TMOD_OFFICIAL_VERSION" ""
    if ($currentOfficial) {
        Write-Host "[INFO] Uma versao oficial do GitHub ($currentOfficial) esta ativa no .env." -ForegroundColor Yellow
        Write-Host "Se desejar voltar a usar a imagem pura do Docker Hub, use a opcao [3] do menu de atualizacao." -ForegroundColor Gray
        Write-Host ""
    }
    $confirm = Read-Host "Deseja verificar e baixar as atualizacoes do Docker Hub agora? (S/N)"
    if ($confirm -notmatch "^[sS]") {
        Write-Host "Atualizacao cancelada." -ForegroundColor Gray
        return
    }

    Ensure-DockerEngine

    $running = [bool](docker ps -q -f name=servidor_tmodloader 2>$null)
    if ($running) {
        Write-Host ""
        Write-Host "[AVISO] O servidor esta rodando. Desligando com seguranca (salvando mundo)..." -ForegroundColor Yellow
        Stop-TerrariaServer
    }

    Write-Host ""
    Write-Host "[DOCKER PULL] Baixando imagem base do tModLoader..." -ForegroundColor Cyan
    docker pull jacobsmile/tmodloader1.4:latest
    Write-Host "[DOCKER PULL] Baixando imagem do Tailscale VPN..." -ForegroundColor Cyan
    docker pull tailscale/tailscale:stable
    Write-Host "[DOCKER PULL] Baixando imagem do Portainer CE..." -ForegroundColor Cyan
    docker pull portainer/portainer-ce:lts

    Write-Host ""
    Write-Host "[BUILD] Reconstruindo imagem local do tModLoader (--pull)..." -ForegroundColor Cyan
    docker-compose build --pull tmodloader

    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Green
    Write-Host " [OK] IMAGENS E DEPENDENCIAS ATUALIZADAS COM SUCESSO!" -ForegroundColor Green
    Write-Host "==================================================================" -ForegroundColor Green
    Write-Host "Dica: Inicie o servidor (Opcao [1]) para rodar com a versao atualizada." -ForegroundColor Cyan

    if ($running) {
        Write-Host ""
        $restart = Read-Host "Deseja iniciar o servidor agora na versao atualizada? (S/N)"
        if ($restart -match "^[sS]") {
            Start-TerrariaServer
        }
    }
}

function Invoke-OfficialReleaseForceUpdate {
    Write-Header "FORCAR ATUALIZACAO COM VERSAO OFICIAL (GITHUB RELEASES)"
    Write-Host "Consultando informacoes dos lancamentos estaveis do tModLoader no GitHub..." -ForegroundColor Cyan

    $latestTag = $null
    try {
        $webResp = Invoke-RestMethod -Uri "https://api.github.com/repos/tModLoader/tModLoader/releases/latest" -Headers @{"User-Agent"="PowerShell-tModLoader-Server"} -TimeoutSec 5 -ErrorAction Stop
        if ($webResp -and $webResp.tag_name) {
            $latestTag = $webResp.tag_name.ToString().Trim()
        }
    } catch {
        # Fallback caso API do GitHub sofra rate limit ou ocorra falha de conexao
    }

    if (-not $latestTag) {
        $latestTag = "v2026.09.3.1"
    }

    Write-Host "Versao oficial mais recente detectada no GitHub: $latestTag" -ForegroundColor Green
    Write-Host ""
    Write-Host "Voce pode aceitar a versao detectada ou digitar uma versao especifica." -ForegroundColor Gray
    Write-Host "Exemplos de entrada aceitos: 9.3.1 | v2026.09.3.1 | latest" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Pressione [Enter] para usar '$latestTag' ou digite a versao desejada:" -ForegroundColor Cyan
    $inputVer = (Read-Host "Versao").Trim()

    $targetVer = if ([string]::IsNullOrWhiteSpace($inputVer)) { $latestTag } else { $inputVer }

    # Normaliza formatos curtos como "9.3.1" para "v2026.09.3.1"
    if ($targetVer -match "^(\d+)\.(\d+)\.(\d+)$") {
        $m = [regex]::Match($targetVer, "^(\d+)\.(\d+)\.(\d+)$")
        $month = [int]$m.Groups[1].Value
        $patch = [int]$m.Groups[2].Value
        $rev   = [int]$m.Groups[3].Value
        $year = (Get-Date).Year
        if ($latestTag -match "^v(\d{4})") {
            $year = $matches[1]
        }
        $targetVer = ("v{0}.{1:D2}.{2}.{3}" -f $year, $month, $patch, $rev)
    } elseif ($targetVer -notmatch "^v" -and $targetVer -ne "latest") {
        $targetVer = "v" + $targetVer
    }

    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Yellow
    Write-Host "CONFIRMACAO DA ATUALIZACAO OFICIAL (CONTINGENCIA):" -ForegroundColor White
    Write-Host "  -> Versao Oficial Alvo : $targetVer" -ForegroundColor Green
    Write-Host "  -> Origem do Pacote    : GitHub Releases (tModLoader/tModLoader)" -ForegroundColor Cyan
    Write-Host "  -> Arquivo de Download : .../releases/download/$targetVer/tModLoader.zip" -ForegroundColor Gray
    Write-Host "==================================================================" -ForegroundColor Yellow
    $confirm = Read-Host "Deseja baixar e compilar o servidor com esta versao oficial agora? (S/N)"
    if ($confirm -notmatch "^[sS]") {
        Write-Host "Operacao cancelada." -ForegroundColor Gray
        return
    }

    Ensure-DockerEngine

    $running = [bool](docker ps -q -f name=servidor_tmodloader 2>$null)
    if ($running) {
        Write-Host ""
        Write-Host "[AVISO] O servidor esta rodando. Desligando com seguranca (salvando mundo)..." -ForegroundColor Yellow
        Stop-TerrariaServer
    }

    Write-Host ""
    Write-Host "[CONFIG] Gravando TMOD_OFFICIAL_VERSION=$targetVer no arquivo .env..." -ForegroundColor Cyan
    Set-EnvValue "TMOD_OFFICIAL_VERSION" $targetVer

    Write-Host "[BUILD] Baixando versao oficial do GitHub e reconstruindo container..." -ForegroundColor Cyan
    docker-compose build --build-arg TMOD_OFFICIAL_VERSION=$targetVer tmodloader

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "[ERRO] Falha ao compilar container com a versao $targetVer." -ForegroundColor Red
        Write-Host "Verifique a conexao com a internet ou se o release '$targetVer' existe no GitHub." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Green
    Write-Host " [OK] SERVIDOR ATUALIZADO COM SUCESSO PARA A VERSAO OFICIAL $targetVer!" -ForegroundColor Green
    Write-Host "==================================================================" -ForegroundColor Green
    Write-Host "A versao do servidor agora bate com a versao da Steam ($targetVer)!" -ForegroundColor Cyan
    Write-Host "O erro 'Your game is using 9.3.1 and the server 9.2.1' foi solucionado." -ForegroundColor Green

    if ($running) {
        Write-Host ""
        $restart = Read-Host "Deseja iniciar o servidor agora com a nova versao? (S/N)"
        if ($restart -match "^[sS]") {
            Start-TerrariaServer
        }
    }
}

function Invoke-ResetToDefaultImage {
    Write-Header "RESETAR PARA IMAGEM PADRAO (DOCKER HUB)"
    $currentOfficial = Get-EnvValue "TMOD_OFFICIAL_VERSION" ""
    if (-not $currentOfficial) {
        Write-Host "[INFO] O servidor ja esta configurado para usar a imagem base padrao do Docker Hub." -ForegroundColor Yellow
        return
    }

    Write-Host "Versao oficial atualmente forcada: $currentOfficial" -ForegroundColor Cyan
    Write-Host "Esta operacao ira remover a versao forcada do .env e recompilar usando a imagem pura do Docker Hub." -ForegroundColor White
    Write-Host ""
    $confirm = Read-Host "Deseja resetar para a imagem padrao do Docker Hub agora? (S/N)"
    if ($confirm -notmatch "^[sS]") {
        Write-Host "Operacao cancelada." -ForegroundColor Gray
        return
    }

    Ensure-DockerEngine

    $running = [bool](docker ps -q -f name=servidor_tmodloader 2>$null)
    if ($running) {
        Write-Host ""
        Write-Host "[AVISO] O servidor esta rodando. Desligando com seguranca (salvando mundo)..." -ForegroundColor Yellow
        Stop-TerrariaServer
    }

    Write-Host ""
    Write-Host "[CONFIG] Limpando TMOD_OFFICIAL_VERSION no arquivo .env..." -ForegroundColor Cyan
    Set-EnvValue "TMOD_OFFICIAL_VERSION" ""

    Write-Host "[BUILD] Recompilando container com a imagem base do Docker Hub..." -ForegroundColor Cyan
    docker-compose build --build-arg TMOD_OFFICIAL_VERSION="" tmodloader

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERRO] Falha ao recompilar container." -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Green
    Write-Host " [OK] SERVIDOR RESETADO PARA A IMAGEM PADRAO DO DOCKER HUB!" -ForegroundColor Green
    Write-Host "==================================================================" -ForegroundColor Green

    if ($running) {
        Write-Host ""
        $restart = Read-Host "Deseja iniciar o servidor agora? (S/N)"
        if ($restart -match "^[sS]") {
            Start-TerrariaServer
        }
    }
}

function Update-TerrariaServer {
    while ($true) {
        Clear-Host
        Write-Header "CENTRAL DE ATUALIZACAO DO SERVIDOR TERRARIA (tModLoader)"
        $currentOfficial = Get-EnvValue "TMOD_OFFICIAL_VERSION" ""
        $activeVerLabel = if ($currentOfficial) {
            "Versao Oficial Forcada (GitHub Releases: $currentOfficial)"
        } else {
            "Padrao (Docker Hub: jacobsmile/tmodloader1.4:latest)"
        }

        Write-Host "  Versao tModLoader Ativa : $activeVerLabel" -ForegroundColor Cyan
        Write-Host "==================================================================" -ForegroundColor DarkCyan
        Write-Host "O tModLoader na Steam dos jogadores atualiza automaticamente. Quando sai uma" -ForegroundColor Gray
        Write-Host "atualizacao nova na Steam e o servidor ainda nao atualizou, ocorre o erro:" -ForegroundColor Gray
        Write-Host "  'Your game is using 9.3.1 and the server 9.2.1'" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Escolha o metodo de atualizacao desejado:" -ForegroundColor White
        Write-Host ""
        Write-Host "  [1] Atualizacao Padrao (Docker Hub - Imagens Base)" -ForegroundColor White
        Write-Host "      -> Baixa as imagens mais recentes do Docker Hub (tModLoader, Tailscale, Portainer)." -ForegroundColor Gray
        Write-Host "      -> Recomendado para manutencao de rotina quando as versoes estao alinhadas." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  [2] Forcar Atualizacao Oficial do tModLoader (GitHub Releases - Contingencia)" -ForegroundColor Green
        Write-Host "      -> Baixa a versao oficial estavel direto do GitHub do tModLoader (ex: 9.3.1 / v2026.09.3.1)." -ForegroundColor Gray
        Write-Host "      -> Resolve NA HORA erros de versao diferente sem precisar esperar o Docker Hub!" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  [3] Resetar para Imagem Padrao do Docker Hub (Remover versao forcada)" -ForegroundColor Yellow
        Write-Host "      -> Remove a versao customizada do GitHub e volta a usar a imagem oficial do Docker Hub." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  [0] Voltar ao Menu Principal" -ForegroundColor Gray
        Write-Host "==================================================================" -ForegroundColor DarkCyan
        Write-Host ""

        $choice = (Read-Host "Escolha uma opcao de atualizacao").Trim()
        if ($choice -eq "0" -or [string]::IsNullOrWhiteSpace($choice)) {
            return
        }

        switch ($choice) {
            "1" {
                Invoke-StandardImageUpdate
                Pause
                return
            }
            "2" {
                Invoke-OfficialReleaseForceUpdate
                Pause
                return
            }
            "3" {
                Invoke-ResetToDefaultImage
                Pause
                return
            }
            default { }
        }
    }
}

function Manage-NamelessDeityProgression {
    $running = Test-IsContainerRunning "servidor_tmodloader"

    # Se o servidor do Terraria estiver OFFLINE, ao clicar em [12] ja sobe automaticamente
    # o Bot Nameless Deity em Modo Simulacao (com mundo e conquistas falsas pre-definidas)
    # para testar todos os comandos pela tela e pelo Discord, desfazendo tudo ao sair!
    if (-not $running) {
        & (Join-Path $PSScriptRoot "testar_bot_nameless.ps1")
        return
    }

    while ($true) {
        Clear-Host
        Write-Header "GUARDIAO NAMELESS DEITY (SERVIDOR ONLINE)"
        $botToken = Get-EnvValue "DISCORD_BOT_TOKEN" ""
        $tokenStatus = if ($botToken) { "Configurado (Ativo)" } else { "Nao configurado (Usando Webhook + Chat do Jogo)" }

        Write-Host "  Bot Discord 'Nameless Deity' : $tokenStatus" -ForegroundColor Cyan
        Write-Host "  Comandos no Chat do Jogo     : !progresso | !proximo | !bosses | !objetivos | !marcar <nome> | !meta <texto>" -ForegroundColor Gray
        Write-Host "  Comandos no Discord          : /progresso | /proximo | /bosses | /objetivos | /marcar <nome> | /meta <texto>" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  [1] Ver Proximo Boss (Invocacao e Bioma) e enviar ao Discord" -ForegroundColor Green
        Write-Host "  [2] Ver Lista Completa de Bosses (Vanilla + Calamity) e enviar ao Discord" -ForegroundColor Cyan
        Write-Host "  [3] Ver Marcos da Campanha e Metas do Grupo" -ForegroundColor Yellow
        Write-Host "  [4] Marcar um Boss ou Objetivo como Concluido" -ForegroundColor White
        Write-Host "  [5] Desmarcar um Boss ou Objetivo (Voltar para Pendente)" -ForegroundColor Gray
        Write-Host "  [6] Adicionar Nova Meta Customizada para o Grupo" -ForegroundColor Magenta
        Write-Host "  [7] Configurar Token do Bot Discord (DISCORD_BOT_TOKEN no .env)" -ForegroundColor Blue
        Write-Host "  [8] Abrir Simulador Isolado do Bot (Testar com conquistas falsas)" -ForegroundColor Green
        Write-Host "  [0] Voltar ao Menu Principal" -ForegroundColor Gray
        Write-Host ""

        $sub = Read-Host "Escolha uma opcao"
        if ($sub -eq "0" -or [string]::IsNullOrWhiteSpace($sub)) { return }

        if ($sub -eq "8") {
            & (Join-Path $PSScriptRoot "testar_bot_nameless.ps1")
            continue
        }

        if ($sub -eq "7") {
            Write-Host ""
            $newToken = Read-Host "Cole o DISCORD_BOT_TOKEN (ou deixe em branco para cancelar)"
            if (-not [string]::IsNullOrWhiteSpace($newToken)) {
                $envPath = Join-Path $RootDir ".env"
                $lines = @()
                if (Test-Path $envPath) {
                    $lines = @(Get-Content $envPath -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch "^DISCORD_BOT_TOKEN=" })
                }
                $lines += "DISCORD_BOT_TOKEN=$($newToken.Trim())"
                [System.IO.File]::WriteAllLines($envPath, [string[]]$lines)
                Write-Host "[OK] DISCORD_BOT_TOKEN salvo no arquivo .env! Reinicie o servidor para conectar o bot." -ForegroundColor Green
            }
            Pause
            continue
        }

        Get-Content (Join-Path $RootDir "scripts\nameless_deity.py") -Raw | docker exec -i servidor_tmodloader tee /terraria-server/scripts/nameless_deity.py >$null

        switch ($sub) {
            "1" { docker exec servidor_tmodloader python3 /terraria-server/scripts/nameless_deity.py next; Pause }
            "2" { docker exec servidor_tmodloader python3 /terraria-server/scripts/nameless_deity.py bosses; Pause }
            "3" { docker exec servidor_tmodloader python3 /terraria-server/scripts/nameless_deity.py objectives; Pause }
            "4" {
                $target = Read-Host "Digite o nome ou ID do Boss/Objetivo para MARCAR (ex: desert scourge, shimmer, lab_jungle)"
                if (-not [string]::IsNullOrWhiteSpace($target)) {
                    docker exec servidor_tmodloader python3 /terraria-server/scripts/nameless_deity.py mark "$target"
                }
                Pause
            }
            "5" {
                $target = Read-Host "Digite o nome ou ID do Boss/Objetivo para DESMARCAR"
                if (-not [string]::IsNullOrWhiteSpace($target)) {
                    docker exec servidor_tmodloader python3 /terraria-server/scripts/nameless_deity.py unmark "$target"
                }
                Pause
            }
            "6" {
                $goalText = Read-Host "Digite a descricao da nova meta do grupo"
                if (-not [string]::IsNullOrWhiteSpace($goalText)) {
                    docker exec servidor_tmodloader python3 /terraria-server/scripts/nameless_deity.py add-goal "$goalText"
                }
                Pause
            }
        }
    }
}

function Show-InteractiveMenu {
    while ($true) {
        Clear-Host
        $running = Test-IsContainerRunning "servidor_tmodloader"
        $statusText = if ($running) { "[ONLINE]" } else { "[OFFLINE]" }
        $currentProvider = (Get-EnvValue "NETWORK_PROVIDER" "radmin").ToUpper()
        $radminIP = Get-RadminIP
        $radminText = if ($radminIP) { "${radminIP}:7777" } else { "Nao detectado" }
        $tsIP = Get-TailscaleIP
        $tsText = if ($tsIP) { "${tsIP}:7777" } else { "Nao detectado" }
        $backupsCount = @(Get-ChildItem -Path (Join-Path $RootDir "Backups") -Filter "backup_*.zip" -ErrorAction SilentlyContinue).Count
        $officialVer = Get-EnvValue "TMOD_OFFICIAL_VERSION" ""
        $verText = if ($officialVer) { "Oficial GitHub ($officialVer)" } else { "Docker Hub (Padrao)" }

        Write-Host "==================================================================" -ForegroundColor Cyan
        Write-Host "         PAINEL DE CONTROLE - SERVIDOR TERRARIA (tModLoader)      " -ForegroundColor White
        Write-Host "==================================================================" -ForegroundColor Cyan
        Write-Host "  Status do Servidor : $statusText (Modo Rede: $currentProvider)"
        Write-Host "  Versao tModLoader  : $verText"
        Write-Host "  IP Radmin VPN      : $radminText"
        Write-Host "  IP Tailscale VPN   : $tsText"
        Write-Host "  Backups Salvos     : $backupsCount / 10 (na pasta Backups/)"
        Write-Host "==================================================================" -ForegroundColor Cyan
        Write-Host "  [1] Iniciar Servidor (Acompanha logs e abre VPN)" -ForegroundColor Green
        Write-Host "  [2] Desligar Servidor com Seguranca (Salva Mundo + Backup)" -ForegroundColor Red
        Write-Host "  [3] Forcar Backup do Mundo Agora (.zip)" -ForegroundColor Cyan
        Write-Host "  [4] Restaurar um Backup Antigo (Escolher da lista)" -ForegroundColor Yellow
        Write-Host "  [5] Ver Logs ao Vivo / Diagnostico de Mods" -ForegroundColor White
        Write-Host "  [6] Enviar Comando para o Console do Terraria (say, save, noon...)" -ForegroundColor Magenta
        Write-Host "  [7] Abrir Painel Web (Portainer - Porta 9443)" -ForegroundColor Blue
        Write-Host "  [8] Executar Bateria de Testes Automatizados (13 Testes)" -ForegroundColor DarkCyan
        Write-Host "  [9] Reverter configuracoes do app neste PC (Firewall, containers, imagens)" -ForegroundColor DarkYellow
        Write-Host "  [10] Alterar Provedor de Rede / VPN (Radmin / Tailscale / Hibrido / Local)" -ForegroundColor Green
        Write-Host "  [11] Atualizar Servidor (Padrao Docker Hub ou Forcar Versao Oficial GitHub)" -ForegroundColor Cyan
        Write-Host "  [12] Guardiao Nameless Deity (Progresso Linear, Bosses, Objetivos e Bot Discord)" -ForegroundColor Yellow
        Write-Host "  [0] Sair" -ForegroundColor Gray
        Write-Host "==================================================================" -ForegroundColor Cyan

        $opt = (Read-Host "Escolha uma opcao").Trim()
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
            "10" {
                $newProv = Select-NetworkProvider -ForceInteractive $true
                Ensure-FirewallRules -Provider $newProv
                Pause
            }
            "11" { Update-TerrariaServer; Pause }
            "12" { Manage-NamelessDeityProgression }
            "0" { return }
            default { }
        }
    }
}

switch ($Action) {
    "Start"       { Start-TerrariaServer }
    "Stop"        { Stop-TerrariaServer }
    "Backup"      { Invoke-ManualBackup }
    "Restore"     { Invoke-RestoreBackup }
    "Logs"        { Show-LogsAndDiagnostics }
    "Command"     { Send-TerrariaCommand }
    "Test"        { & (Join-Path $PSScriptRoot "testar_servidor.ps1") }
    "Uninstall"   { Uninstall-TerrariaEnvironment }
    "Network"     { Select-NetworkProvider -ForceInteractive $true | Out-Null }
    "Update"      { Update-TerrariaServer }
    "Progression" { Manage-NamelessDeityProgression }
    "Menu"        { Show-InteractiveMenu }
}
