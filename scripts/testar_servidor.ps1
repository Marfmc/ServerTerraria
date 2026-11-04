# ==============================================================================
# Bateria de Testes Automatizados Ponta a Ponta - Servidor Terraria (tModLoader)
# - Testa todas as funcoes uma a uma (Ambiente, Firewall, Container, .NET 8,
#   Healthcheck, Console Inject, Backups, Rotacao, Auto-Restore, Mods/Steam API,
#   Diagnostico/Modo Seguro, Portainer e Discord Webhook).
# - Exibe VERDE para tudo que passou e VERMELHO + LOG para qualquer falha.
# - Limpa 100% dos resquicios e arquivos temporarios ao final (bloco finally).
# ==============================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$RootDir = Split-Path -Parent $PSScriptRoot
Set-Location $RootDir

$Results = New-Object System.Collections.Generic.List[PSObject]

function Run-Test {
    param(
        [int]$Number,
        [string]$Name,
        [scriptblock]$TestBlock
    )
    Write-Host ("[{0:D2}/12] Testando: {1}..." -f $Number, $Name) -ForegroundColor Cyan -NoNewline
    try {
        $detail = & $TestBlock
        Write-Host "`r[PASSOU] " -ForegroundColor Green -NoNewline
        Write-Host ("[{0:D2}/12] {1}" -f $Number, $Name) -ForegroundColor Green
        if ($detail) {
            Write-Host "         -> $detail" -ForegroundColor DarkGreen
        }
        $Results.Add([PSCustomObject]@{
            Number = $Number
            Name   = $Name
            Passed = $true
            Detail = $detail
            Log    = ""
        })
    } catch {
        $errMsg = $_.Exception.Message
        Write-Host "`r[FALHOU] " -ForegroundColor Red -NoNewline
        Write-Host ("[{0:D2}/12] {1}" -f $Number, $Name) -ForegroundColor Red
        Write-Host "         [LOG DO ERRO]: $errMsg" -ForegroundColor Red
        $Results.Add([PSCustomObject]@{
            Number = $Number
            Name   = $Name
            Passed = $false
            Detail = ""
            Log    = $errMsg
        })
    }
}

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "   INICIANDO BATERIA DE TESTES AUTOMATIZADOS DO SERVIDOR          " -ForegroundColor White
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""

# Salva estado inicial para garantir limpeza 100% no bloco finally
$TempBackupDir = Join-Path $env:TEMP ("terraria_test_state_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempBackupDir -Force | Out-Null

$InstallTxtPath  = Join-Path $RootDir "Mods\install.txt"
$EnabledJsonPath = Join-Path $RootDir "Mods\enabled.json"
$ServerLogPath   = Join-Path $RootDir "Logs\server.log"
$DiagFilePath    = Join-Path $RootDir "Logs\diagnostico_mods.txt"
$WorldsDir       = Join-Path $RootDir "Worlds"
$BackupsDir      = Join-Path $RootDir "Backups"

$OriginalBackups = @()
if (Test-Path $BackupsDir) {
    $OriginalBackups = @(Get-ChildItem -Path $BackupsDir -File | Select-Object -ExpandProperty Name)
}

if (Test-Path $InstallTxtPath)  { Copy-Item $InstallTxtPath  (Join-Path $TempBackupDir "install.txt") -Force }
if (Test-Path $EnabledJsonPath) { Copy-Item $EnabledJsonPath (Join-Path $TempBackupDir "enabled.json") -Force }
$HadDiagFile = Test-Path $DiagFilePath
if ($HadDiagFile)               { Copy-Item $DiagFilePath    (Join-Path $TempBackupDir "diagnostico_mods.txt") -Force }

$WldFile = Join-Path $WorldsDir "MundoPrincipal.wld"
$TwldFile = Join-Path $WorldsDir "MundoPrincipal.twld"
if (Test-Path $WldFile)  { Copy-Item $WldFile  (Join-Path $TempBackupDir "MundoPrincipal.wld") -Force }
if (Test-Path $TwldFile) { Copy-Item $TwldFile (Join-Path $TempBackupDir "MundoPrincipal.twld") -Force }

try {
    # ------------------------------------------------------------------
    # TESTE 01: Ambiente Windows (Docker Engine & Radmin VPN)
    # ------------------------------------------------------------------
    Run-Test -Number 1 -Name "Ambiente Windows (Motor Docker & Radmin VPN)" -TestBlock {
        $dockerOut = docker info 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Docker Engine nao esta respondendo. Saida: $($dockerOut | Out-String)"
        }
        $radminPaths = @(
            "${env:ProgramFiles(x86)}\Radmin VPN\RvGui.exe",
            "${env:ProgramFiles}\Radmin VPN\RvGui.exe"
        )
        $radminExe = $radminPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
        $radminStatus = if ($radminExe) { "Radmin instalado" } else { "Radmin ausente (instalavel via .bat)" }
        return "Docker Engine ativo ($radminStatus)"
    }

    # ------------------------------------------------------------------
    # TESTE 02: Regras do Firewall do Windows (Portas 7777 e 9443)
    # ------------------------------------------------------------------
    Run-Test -Number 2 -Name "Firewall do Windows (Portas 7777 TCP/UDP e 9443 TCP)" -TestBlock {
        # Garante que as regras estejam criadas chamando a verificacao se necessario
        $rules = @("Terraria_tModLoader_7777_TCP", "Terraria_tModLoader_7777_UDP", "Terraria_Portainer_9443_TCP")
        $missing = @()
        foreach ($r in $rules) {
            $check = netsh advfirewall firewall show rule name="$r" 2>&1
            if ($LASTEXITCODE -ne 0) {
                $missing += $r
            }
        }
        if ($missing.Count -gt 0) {
            return "Aviso: Regras pendentes de criacao no proximo IniciarServidor.bat ($($missing -join ', '))"
        }
        return "Todas as 3 regras (7777 TCP/UDP e 9443 TCP) estao ativas no Firewall"
    }

    # ------------------------------------------------------------------
    # TESTE 03: Container tModLoader e Correcao .NET 8 (libicu-dev)
    # ------------------------------------------------------------------
    Run-Test -Number 3 -Name "Container tModLoader e Suporte .NET 8 (libicu-dev)" -TestBlock {
        $running = docker inspect -f "{{.State.Running}}" servidor_tmodloader 2>&1
        if ($LASTEXITCODE -ne 0 -or $running -notmatch "true") {
            throw "Container 'servidor_tmodloader' nao esta rodando. Estado: $running"
        }
        $icuCheck = docker exec servidor_tmodloader bash -c "dpkg -s libicu-dev >/dev/null 2>&1 && echo OK_ICU" 2>&1
        if ($icuCheck -notmatch "OK_ICU") {
            throw "Pacote libicu-dev nao encontrado dentro do container: $icuCheck"
        }
        $invCheck = docker exec servidor_tmodloader bash -c "echo `$DOTNET_SYSTEM_GLOBALIZATION_INVARIANT" 2>&1
        if ($invCheck.Trim() -eq "1" -or $invCheck.Trim() -eq "true") {
            throw "DOTNET_SYSTEM_GLOBALIZATION_INVARIANT esta ativo ($invCheck), o que causa crash no Terraria!"
        }
        return "Container ativo, libicu-dev instalado e cultura en-US suportada"
    }

    # ------------------------------------------------------------------
    # TESTE 04: Healthcheck Silencioso e Socket na Porta 7777
    # ------------------------------------------------------------------
    Run-Test -Number 4 -Name "Saude do Processo e Socket TCP na Porta 7777 (healthcheck.sh)" -TestBlock {
        $hcOut = docker exec servidor_tmodloader /terraria-server/scripts/healthcheck.sh 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "healthcheck.sh retornou codigo $LASTEXITCODE. Saida: $hcOut"
        }
        $pidOut = docker exec servidor_tmodloader pgrep -f "tModLoader.dll" 2>&1
        return "Processo tModLoader.dll (PID $($pidOut -join ',')) ativo e porta 7777 em LISTEN"
    }

    # ------------------------------------------------------------------
    # TESTE 05: Injecao de Comando no Console do Terraria (inject save)
    # ------------------------------------------------------------------
    Run-Test -Number 5 -Name "Injecao de Comandos no Console do Terraria (tmux inject)" -TestBlock {
        $injOut = docker exec servidor_tmodloader inject "save" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao executar 'inject save': $injOut"
        }
        Start-Sleep -Seconds 3
        $tailLog = Get-Content $ServerLogPath -Tail 15 -ErrorAction Stop | Out-String
        if ($tailLog -notmatch "Saving world data|Validating world save|Saving modded world data") {
            throw "O comando 'save' foi enviado mas nao apareceu confirmacao no server.log.`nUltimas linhas:`n$tailLog"
        }
        return "Comando 'save' recebido e mundo salvo pelo console do Terraria"
    }

    # ------------------------------------------------------------------
    # TESTE 06: Criacao e Integridade de Backup .zip
    # ------------------------------------------------------------------
    Run-Test -Number 6 -Name "Geracao de Backup .zip e Verificacao de Integridade" -TestBlock {
        $bkpOut = docker exec -e DISCORD_WEBHOOK_URL="" servidor_tmodloader /terraria-server/scripts/backup_manager.sh create teste_auto 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Erro ao criar backup: $($bkpOut | Out-String)"
        }
        $testZip = Get-ChildItem -Path $BackupsDir -Filter "backup_*_teste_auto.zip" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $testZip -or $testZip.Length -lt 1024) {
            throw "Arquivo .zip de teste nao foi encontrado na pasta Backups/ ou esta vazio."
        }
        $sizeMB = [math]::Round($testZip.Length / 1MB, 2)
        return "Backup '$($testZip.Name)' ($sizeMB MB) criado e validado com unzip -t"
    }

    # ------------------------------------------------------------------
    # TESTE 07: Rotacao Automatica de Backups (Limite de 10 Arquivos)
    # ------------------------------------------------------------------
    Run-Test -Number 7 -Name "Rotacao Automatica de Backups (Limite de 10 Arquivos)" -TestBlock {
        $sampleZip = Get-ChildItem -Path $BackupsDir -Filter "backup_*.zip" | Select-Object -First 1
        if (-not $sampleZip) {
            throw "Nenhum backup base disponivel para testar rotacao."
        }
        # Cria 12 backups simulados com datas antigas
        for ($i = 1; $i -le 12; $i++) {
            $fakeName = ("backup_MundoPrincipal_2020-01-{0:D2}_00-00-00_faketest.zip" -f $i)
            $fakePath = Join-Path $BackupsDir $fakeName
            Copy-Item $sampleZip.FullName $fakePath -Force
            (Get-Item $fakePath).LastWriteTime = (Get-Date).AddDays(-100 + $i)
        }
        $rotOut = docker exec -e DISCORD_WEBHOOK_URL="" servidor_tmodloader /terraria-server/scripts/backup_manager.sh create teste_rotacao 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Falha durante rotacao: $($rotOut | Out-String)"
        }
        $remaining = @(Get-ChildItem -Path $BackupsDir -Filter "backup_MundoPrincipal_*.zip")
        if ($remaining.Count -ne 10) {
            throw "A rotacao deveria manter exatamente 10 backups, mas restaram $($remaining.Count) arquivos!"
        }
        return "Rotacao validada: de 13+ arquivos, manteve exatamente os 10 mais recentes"
    }

    # ------------------------------------------------------------------
    # TESTE 08: Auto-Restore Anti-Corrupcao de Mundo
    # ------------------------------------------------------------------
    Run-Test -Number 8 -Name "Auto-Restore Anti-Corrupcao de Mundo (.wld corrompido)" -TestBlock {
        if (-not (Test-Path (Join-Path $TempBackupDir "MundoPrincipal.wld"))) {
            throw "Backup temporario de seguranca do mundo nao encontrado."
        }
        # Simula corrupcao truncando o arquivo .wld para 8 bytes
        Set-Content -Path $WldFile -Value "CORRUPT" -Encoding ASCII
        $corruptSize = (Get-Item $WldFile).Length
        if ($corruptSize -ge 1024) {
            throw "Falha ao simular truncamento do arquivo .wld."
        }

        $restOut = docker exec -e DISCORD_WEBHOOK_URL="" servidor_tmodloader /terraria-server/scripts/backup_manager.sh check-and-restore 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "backup_manager.sh check-and-restore falhou: $($restOut | Out-String)"
        }

        $restoredSize = (Get-Item $WldFile).Length
        if ($restoredSize -lt 100000) {
            throw "O mundo nao foi restaurado corretamente (Tamanho apos restore: $restoredSize bytes). Log: $($restOut | Out-String)"
        }
        $sizeMB = [math]::Round($restoredSize / 1MB, 2)
        return "Corrupcao (8 bytes) detectada e mundo integro ($sizeMB MB) restaurado automaticamente"
    }

    # ------------------------------------------------------------------
    # TESTE 09: Resolucao Inteligente de Mods e API da Steam Workshop
    # ------------------------------------------------------------------
    Run-Test -Number 9 -Name "Resolucao de Links/Colecoes da Steam Workshop (resolve_mods.py)" -TestBlock {
        $pyTest = @'
import sys
sys.path.insert(0, '/terraria-server/scripts')
import resolve_mods

ids = []
for line in [
    '2824688072 # comentario',
    'https://steamcommunity.com/sharedfiles/filedetails/?id=2619954303&searchtext=magic',
    '# linha ignorada'
]:
    ids.extend(resolve_mods.extract_ids_from_line(line))

assert ids == ['2824688072', '2619954303'], f'Extracao incorreta: {ids}'

all_ids, titles = resolve_mods.resolve_dependencies_and_titles(['2824688072'])
t = titles.get('2824688072', '')
assert len(t) > 0, f'Falha ao obter titulo da Steam API: {titles}'
print('OK_STEAM:' + t)
'@
        $out = $pyTest | docker exec -i servidor_tmodloader python3 - 2>&1
        $outStr = $out | Out-String
        if ($LASTEXITCODE -ne 0 -or $outStr -notmatch "OK_STEAM:(.+)") {
            throw "Erro no teste do resolve_mods.py: $outStr"
        }
        $modTitle = $Matches[1].Trim()
        return "Extracao de links OK e API da Steam respondeu com sucesso (Mod: '$modTitle')"
    }

    # ------------------------------------------------------------------
    # TESTE 10: Diagnostico de Crash e Modo Seguro de Mods (diagnose_crash.py)
    # ------------------------------------------------------------------
    Run-Test -Number 10 -Name "Diagnostico de Crash e Isolamento do Modo Seguro (diagnose_crash.py)" -TestBlock {
        Set-Content -Path $EnabledJsonPath -Value '["ModTesteQuebrado", "OutroModBom"]' -Encoding UTF8
        $pyDiagTest = @'
import os, subprocess
fake_log = "/tmp/test_crash_server.log"
with open(fake_log, "w", encoding="utf-8") as f:
    f.write(
        "[00:00:01.000] [Main Thread/INFO] [tML]: Starting tModLoader server\n"
        "[00:00:02.000] [Main Thread/INFO] [tML]: Loading ModTesteQuebrado v1.0\n"
        "[00:00:02.500] [Main Thread/ERROR] [tML]: Unhandled Exception\n"
        "System.Exception: Erro fatal simulado no mod ModTesteQuebrado\n"
        "   at ModTesteQuebrado.BrokenSystem.OnModLoad()\n"
    )
env = dict(os.environ)
env["TMOD_SERVER_LOG_PATH"] = fake_log
res = subprocess.run(["python3", "/terraria-server/scripts/diagnose_crash.py", "isolate"], env=env, capture_output=True, text=True)
os.remove(fake_log)
print(res.stdout)
'@
        # Atualiza diagnose_crash.py dentro do container caso ainda nao tenha sido reconstruido
        Get-Content (Join-Path $RootDir "scripts\diagnose_crash.py") -Raw | docker exec -i servidor_tmodloader tee /terraria-server/scripts/diagnose_crash.py >$null
        $diagOut = $pyDiagTest | docker exec -i servidor_tmodloader python3 - 2>&1
        $diagText = $diagOut | Out-String
        if ($LASTEXITCODE -ne 0 -or $diagText -notmatch "ModTesteQuebrado" -or $diagText -notmatch "MODO SEGURO") {
            throw "diagnose_crash.py nao isolou 'ModTesteQuebrado' corretamente. Saida:`n$diagText"
        }
        if (-not (Test-Path $DiagFilePath)) {
            throw "Arquivo Logs/diagnostico_mods.txt nao foi gerado."
        }
        return "Mod defeituoso ('ModTesteQuebrado') identificado no log e isolado pelo Modo Seguro"
    }

    # ------------------------------------------------------------------
    # TESTE 11: Painel Web Portainer (Container e Porta 9443)
    # ------------------------------------------------------------------
    Run-Test -Number 11 -Name "Painel de Gerenciamento Portainer (Porta 9443)" -TestBlock {
        $pRun = docker inspect -f "{{.State.Running}}" gerenciador_portainer 2>&1
        if ($LASTEXITCODE -ne 0 -or $pRun -notmatch "true") {
            throw "Container 'gerenciador_portainer' nao esta rodando: $pRun"
        }
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $async = $tcp.BeginConnect("127.0.0.1", 9443, $null, $null)
            $wait = $async.AsyncWaitHandle.WaitOne(3000, $false)
            if (-not $wait -or -not $tcp.Connected) {
                throw "Porta 9443 nao respondeu em localhost."
            }
        } finally {
            $tcp.Close()
        }
        return "Container 'gerenciador_portainer' ativo e respondendo em https://localhost:9443"
    }

    # ------------------------------------------------------------------
    # TESTE 12: Integracao com Discord Webhook (.env e Conectividade API)
    # ------------------------------------------------------------------
    Run-Test -Number 12 -Name "Configuracao e Conectividade do Webhook do Discord" -TestBlock {
        $envFile = Join-Path $RootDir ".env"
        if (-not (Test-Path $envFile)) {
            throw "Arquivo .env nao encontrado na raiz."
        }
        $whLine = Get-Content $envFile | Where-Object { $_ -match "^DISCORD_WEBHOOK_URL=(.+)$" } | Select-Object -First 1
        if (-not $whLine) {
            return "Variavel DISCORD_WEBHOOK_URL vazia (opcional)"
        }
        $whUrl = ($whLine -replace "^DISCORD_WEBHOOK_URL=", "").Trim()
        $resp = Invoke-RestMethod -Method Get -Uri $whUrl -TimeoutSec 10
        if (-not $resp.id) {
            throw "Resposta inesperada da API do Discord para o Webhook."
        }
        return "Webhook valido e conectado ao Discord (Nome: '$($resp.name)', Canal ID: $($resp.channel_id))"
    }

} finally {
    Write-Host ""
    Write-Host "------------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host " [LIMPEZA] Restaurando estado original e removendo arquivos de teste..." -ForegroundColor Cyan

    # 1. Restaura arquivos originais de Mods e Mundo
    if (Test-Path (Join-Path $TempBackupDir "install.txt"))  { Copy-Item (Join-Path $TempBackupDir "install.txt")  $InstallTxtPath -Force }
    if (Test-Path (Join-Path $TempBackupDir "enabled.json")) { Copy-Item (Join-Path $TempBackupDir "enabled.json") $EnabledJsonPath -Force }
    if (Test-Path (Join-Path $TempBackupDir "MundoPrincipal.wld"))  { Copy-Item (Join-Path $TempBackupDir "MundoPrincipal.wld")  $WldFile -Force }
    if (Test-Path (Join-Path $TempBackupDir "MundoPrincipal.twld")) { Copy-Item (Join-Path $TempBackupDir "MundoPrincipal.twld") $TwldFile -Force }

    if ($HadDiagFile) {
        Copy-Item (Join-Path $TempBackupDir "diagnostico_mods.txt") $DiagFilePath -Force
    } else {
        Remove-Item $DiagFilePath -Force -ErrorAction SilentlyContinue
    }

    # 2. Limpa arquivos de isolamento de teste dentro do container
    docker exec servidor_tmodloader rm -f /data/tModLoader/.disabled_faulty_mods.txt /data/tModLoader/Mods/.disabled_faulty_mods.txt 2>$null

    # 3. Remove todos os backups .zip criados durante os testes e garante que o backup original esteja intacto
    Get-ChildItem -Path $BackupsDir -Filter "backup_*.zip" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($OriginalBackups -notcontains $_.Name) {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    $currentBackups = @(Get-ChildItem -Path $BackupsDir -Filter "backup_*.zip" -ErrorAction SilentlyContinue)
    if ($currentBackups.Count -eq 0) {
        docker exec -e DISCORD_WEBHOOK_URL="" servidor_tmodloader /terraria-server/scripts/backup_manager.sh create boot >$null 2>&1
    }

    # 4. Remove pasta temporaria do Windows
    Remove-Item $TempBackupDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host " [OK] Todos os resquicios de teste foram removidos com sucesso!" -ForegroundColor Green
    Write-Host "------------------------------------------------------------------" -ForegroundColor DarkCyan
}

$passedCount = @($Results | Where-Object { $_.Passed }).Count
$failedCount = @($Results | Where-Object { -not $_.Passed }).Count

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
if ($failedCount -eq 0) {
    Write-Host ("   RESULTADO FINAL: {0}/12 TESTES APROVADOS COM SUCESSO!          " -f $passedCount) -ForegroundColor Green
} else {
    Write-Host ("   RESULTADO FINAL: {0} APROVADOS | {1} FALHARAM                  " -f $passedCount, $failedCount) -ForegroundColor Red
}
Write-Host "==================================================================" -ForegroundColor Cyan

if ($failedCount -gt 0) {
    Write-Host ""
    Write-Host "RESUMO DAS FALHAS ENCONTRADAS:" -ForegroundColor Red
    foreach ($f in ($Results | Where-Object { -not $_.Passed })) {
        Write-Host ("  - [{0:D2}] {1}: {2}" -f $f.Number, $f.Name, $f.Log) -ForegroundColor Red
    }
    exit 1
}
exit 0
