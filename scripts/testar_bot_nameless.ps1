# ==============================================================================
# Simulador & Bancada de Testes Isolada - Bot Discord "Nameless Deity"
# - Ao abrir (Opcao [12] do PainelMenu), sobe APENAS o bot Nameless Deity ja com
#   configuracoes falsas de mundo (.twld) e progressao pre-definidas em Sandbox
# - Abre a tela interativa para voce testar os comandos e funcoes um por um
#   (tanto pela tela quanto digitando /progresso, /proximo, /marcar no Discord)
# - Ao sair ([0]), DESFAZ TUDO: desliga o bot, apaga as mensagens de teste do
#   Discord e restaura tudo ao estado inicial!
# ==============================================================================
param(
    [switch]$AutoExit = $false
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"

$RootDir = Split-Path -Parent $PSScriptRoot
Set-Location $RootDir

$ScriptPy = Join-Path $RootDir "scripts\nameless_deity.py"
$EnvFile  = Join-Path $RootDir ".env"

function Wait-KeyPress {
    Write-Host ""
    Write-Host "Pressione ENTER para voltar ao painel do Nameless Deity..." -ForegroundColor DarkGray -NoNewline
    $null = Read-Host
}

function Get-LocalEnvValue([string]$Key) {
    if (Test-Path $EnvFile) {
        $line = Get-Content $EnvFile -ErrorAction SilentlyContinue |
            Where-Object { $_ -match "^$([regex]::Escape($Key))=(.*)$" } |
            Select-Object -First 1
        if ($line -match "^$([regex]::Escape($Key))=(.*)$") {
            return $Matches[1].Trim()
        }
    }
    return ""
}

$WebhookUrl = Get-LocalEnvValue "DISCORD_WEBHOOK_URL"
$BotToken   = Get-LocalEnvValue "DISCORD_BOT_TOKEN"

# Cria ambiente Sandbox 100% isolado em $env:TEMP para nao tocar nos arquivos reais de Worlds/
$SandboxDir = Join-Path $env:TEMP ("nameless_bot_test_" + [guid]::NewGuid().ToString("N"))
$SimWorldsDir = Join-Path $SandboxDir "Worlds"
$SimModsDir   = Join-Path $SandboxDir "Mods"
New-Item -ItemType Directory -Path $SimWorldsDir -Force | Out-Null
New-Item -ItemType Directory -Path $SimModsDir   -Force | Out-Null

$SimConsoleLog      = Join-Path $SandboxDir "current_console.log"
$SimServerLog       = Join-Path $SandboxDir "server.log"
$SentMessagesRecord = Join-Path $SandboxDir "sent_discord_messages.txt"
$BotStdoutLog       = Join-Path $SandboxDir "bot_stdout.log"
$BotStderrLog       = Join-Path $SandboxDir "bot_stderr.log"

Set-Content -Path $SimConsoleLog -Value "" -Encoding UTF8
Set-Content -Path $SimServerLog  -Value "" -Encoding UTF8
Set-Content -Path (Join-Path $SimModsDir "enabled.json") -Value '["CalamityMod", "CalamityModMusic", "NoxusBoss"]' -Encoding UTF8

$env:TMOD_WORLDNAME            = "MundoSimuladoTeste"
$env:TMOD_WORLDS_DIR           = $SimWorldsDir
$env:TMOD_MODS_DIR             = $SimModsDir
$env:TMOD_CONSOLE_LOG          = $SimConsoleLog
$env:TMOD_SERVER_LOG_PATH      = $SimServerLog
$env:NAMELESS_RECORD_SENT_FILE = $SentMessagesRecord

# Backup preventivo caso exista algum arquivo na pasta Worlds/ real
$RealWorldsDir = Join-Path $RootDir "Worlds"
$RealProgFiles = @()
if (Test-Path $RealWorldsDir) {
    $RealProgFiles = @(Get-ChildItem -Path $RealWorldsDir -Filter "*_progression.json" -File -ErrorAction SilentlyContinue)
    foreach ($pf in $RealProgFiles) {
        Copy-Item $pf.FullName (Join-Path $SandboxDir ("backup_real_" + $pf.Name)) -Force
    }
}

$BotProcess = $null

try {
    Clear-Host
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "   SUBINDO BOT 'NAMELESS DEITY' COM MUNDO E PROGRESSAO FALSOS     " -ForegroundColor White
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host ""

    # 1. Pre-configura silenciosamente o mundo falso (.twld) e conquistas pre-definidas
    #    (sem enviar Webhook ainda, para que voce mesmo dispare os testes pela tela!)
    Write-Host " [1/3] Gerando mundo falso (.twld) e progressao pre-definida..." -ForegroundColor Cyan
    $env:DISCORD_WEBHOOK_URL = ""
    $env:DISCORD_BOT_TOKEN   = ""

    $pySeed = @'
import gzip, os, struct, sys
sys.path.insert(0, "scripts")
import nameless_deity as nd

worlds_dir = os.environ["TMOD_WORLDS_DIR"]
world_name = os.environ["TMOD_WORLDNAME"]

# Cria arquivo .twld GZip NBT simulado com King Slime, Desert Scourge e Eye of Cthulhu derrotados
buf = bytearray()
buf.append(10)
buf.extend(struct.pack(">H", 4) + b"root")
for flag in (b"downedSlimeKing", b"downedDesertScourge", b"downedBoss1"):
    buf.append(1)
    buf.extend(struct.pack(">H", len(flag)) + flag + struct.pack(">b", 1))
buf.append(0)

with gzip.open(os.path.join(worlds_dir, f"{world_name}.twld"), "wb") as gz:
    gz.write(bytes(buf))

nd.sync_from_world_files()
nd.mark_target("shimmer", completed=True, actor="Simulador Inicial")
nd.mark_target("sunken_sea", completed=True, actor="Simulador Inicial")
nd.add_custom_goal("Construir Arena para Skeletron (Meta Pre-definida)", actor="Simulador Inicial")
'@
    $pySeed | python -
    Write-Host "       [OK] Mundo 'MundoSimuladoTeste.twld' pronto!" -ForegroundColor Green
    Write-Host "            -> Bosses derrotados : King Slime, Desert Scourge, Eye of Cthulhu" -ForegroundColor DarkGreen
    Write-Host "            -> Proximo Boss      : Crabulon (Glowing Mushroom)" -ForegroundColor DarkGreen
    Write-Host "            -> Marcos concluidos : Shimmer, Sunken Sea + 1 Meta Customizada" -ForegroundColor DarkGreen

    # 2. Restaura as credenciais reais de Webhook e Bot Token para os seus testes
    $env:DISCORD_WEBHOOK_URL = $WebhookUrl
    $env:DISCORD_BOT_TOKEN   = $BotToken

    Write-Host ""
    Write-Host " [2/3] Validando conexao com a API do Discord..." -ForegroundColor Cyan
    if ($BotToken) {
        $headers = @{ Authorization = "Bot $BotToken" }
        $botMe = Invoke-RestMethod -Method Get -Uri "https://discord.com/api/v10/users/@me" -Headers $headers -TimeoutSec 10
        Write-Host "       [OK] Bot autenticado: $($botMe.username) (ID: $($botMe.id))" -ForegroundColor Green
    } else {
        Write-Host "       [AVISO] DISCORD_BOT_TOKEN vazio no .env (usando apenas Webhook)." -ForegroundColor Yellow
    }

    # 3. Inicia o processo do Bot em background isolado (-WindowStyle Hidden para nao travar o teclado)
    Write-Host ""
    Write-Host " [3/3] Subindo daemon do Bot Nameless Deity e registrando Slash Commands..." -ForegroundColor Cyan
    $BotProcess = Start-Process -FilePath "python" `
        -ArgumentList "`"$ScriptPy`" daemon" `
        -RedirectStandardOutput $BotStdoutLog `
        -RedirectStandardError $BotStderrLog `
        -WindowStyle Hidden -PassThru

    $connected = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        if ($BotProcess.HasExited) {
            $errOut = Get-Content $BotStderrLog -ErrorAction SilentlyContinue | Out-String
            throw "Processo do bot encerrou inesperadamente: $errOut"
        }
        if (Test-Path $BotStdoutLog) {
            $logContent = Get-Content $BotStdoutLog -Raw -ErrorAction SilentlyContinue
            if ($logContent -match "conectado ao Discord") { $connected = $true }
            if ($logContent -match "Slash Commands .* registrados") { break }
        }
    }
    if ($connected) {
        Write-Host "       [OK] Bot ONLINE no Discord (PID: $($BotProcess.Id))! Pronto para testar!" -ForegroundColor Green
    } else {
        Write-Host "       [AVISO] Bot iniciado em segundo plano (PID: $($BotProcess.Id))." -ForegroundColor Yellow
    }

    if ($AutoExit) {
        Write-Host ""
        Write-Host " [AUTO-TEST] Disparando teste automatico de /progresso e /proximo..." -ForegroundColor Cyan
        $null = python $ScriptPy status | Out-String
        $null = python $ScriptPy next | Out-String
        Start-Sleep -Seconds 2
        return
    }

    Start-Sleep -Seconds 1

    # ==================================================================
    # TELA DO PAINEL DE TESTES (AGORA VOCE TESTA OS COMANDOS PELA TELA!)
    # ==================================================================
    while ($true) {
        Clear-Host
        $botAlive = ($null -ne $BotProcess -and -not $BotProcess.HasExited)
        $statusBadge = if ($botAlive) { "[ONLINE NO DISCORD - PID $($BotProcess.Id)]" } else { "[PARADO]" }
        $summaryLine = (python $ScriptPy summary-line | Out-String).Trim()
        $sentCount = 0
        if (Test-Path $SentMessagesRecord) {
            $sentCount = @(Get-Content $SentMessagesRecord | Where-Object { $_.Trim() -ne "" }).Count
        }

        Write-Host "==================================================================" -ForegroundColor Cyan
        Write-Host "   GUARDIAO NAMELESS DEITY - PAINEL DE TESTES E SIMULACAO         " -ForegroundColor White
        Write-Host "==================================================================" -ForegroundColor Cyan
        Write-Host "  Status do Bot      : $statusBadge" -ForegroundColor Green
        Write-Host "  Mundo Falso Ativo  : MundoSimuladoTeste (.twld + JSON em Sandbox)" -ForegroundColor Cyan
        Write-Host "  Progressao Atual   : $summaryLine" -ForegroundColor Yellow
        Write-Host "  Msgs no Discord    : $sentCount mensagem(ns) enviadas nesta sessao" -ForegroundColor Gray
        Write-Host "------------------------------------------------------------------" -ForegroundColor DarkCyan
        Write-Host "  VOCE TAMBEM PODE TESTAR DIRETO LA NO CANAL DO DISCORD DIGITANDO:" -ForegroundColor Cyan
        Write-Host "    /progresso  |  /proximo  |  /bosses  |  /objetivos  |  /marcar" -ForegroundColor White
        Write-Host "==================================================================" -ForegroundColor Cyan
        Write-Host "  [1] Testar Comando /progresso (Ver resumo e enviar Embed no Discord)" -ForegroundColor Green
        Write-Host "  [2] Testar Comando /proximo   (Ver Proximo Boss, Invocacao e Bioma)" -ForegroundColor Cyan
        Write-Host "  [3] Testar Comando /bosses    (Ver Linha do Tempo e enviar no Discord)" -ForegroundColor Yellow
        Write-Host "  [4] Testar Comando /objetivos (Ver Marcos da Campanha e Metas)" -ForegroundColor White
        Write-Host "  [5] SIMULAR Abate do Proximo Boss Ao Vivo (Injeta no log e avisa Discord!)" -ForegroundColor Green
        Write-Host "  [6] Testar Comando /marcar    (Concluir um Boss, Marco ou Meta)" -ForegroundColor Cyan
        Write-Host "  [7] Testar Comando /desmarcar (Voltar um Boss, Marco ou Meta para pendente)" -ForegroundColor Gray
        Write-Host "  [8] Testar Comando /meta      (Criar nova Meta Customizada do grupo)" -ForegroundColor Magenta
        Write-Host "  [9] Ver Log Ao Vivo do Bot Nameless Deity" -ForegroundColor DarkCyan
        Write-Host "  [0] ENCERRAR TESTES, APAGAR TUDO DO DISCORD E VOLTAR AO ESTADO INICIAL" -ForegroundColor Red
        Write-Host "==================================================================" -ForegroundColor Cyan

        $opt = (Read-Host "Escolha uma opcao [0-9]").Trim()
        Write-Host ""
        switch ($opt) {
            "1" {
                Write-Host "Executando /progresso..." -ForegroundColor Cyan
                python $ScriptPy status
                Write-Host "[OK] Painel /progresso enviado para o canal do Discord!" -ForegroundColor Green
                Wait-KeyPress
            }
            "2" {
                Write-Host "Executando /proximo..." -ForegroundColor Cyan
                python $ScriptPy next
                Write-Host "[OK] Guia /proximo enviado para o canal do Discord!" -ForegroundColor Green
                Wait-KeyPress
            }
            "3" {
                $fase = (Read-Host "Filtrar fase? Digite pre, hard, post (ou apenas ENTER para ver todas)").Trim()
                Write-Host "Executando /bosses..." -ForegroundColor Cyan
                if ([string]::IsNullOrWhiteSpace($fase)) {
                    python $ScriptPy bosses
                } else {
                    python $ScriptPy bosses "$fase"
                }
                Write-Host ""
                Write-Host "[OK] Linha do tempo de Bosses enviada para o canal do Discord!" -ForegroundColor Green
                Wait-KeyPress
            }
            "4" {
                Write-Host "Executando /objetivos..." -ForegroundColor Cyan
                python $ScriptPy objectives
                Write-Host ""
                Write-Host "[OK] Lista de Marcos e Metas enviada para o canal do Discord!" -ForegroundColor Green
                Wait-KeyPress
            }
            "5" {
                $nxtName = (python -c "import sys; sys.path.insert(0, 'scripts'); import nameless_deity as nd; b = nd.get_next_boss(); print(b['name'] if b else '')" | Out-String).Trim()
                if ($nxtName) {
                    Write-Host "[SIMULADOR] Simulando no log do servidor: '$nxtName has been defeated!'..." -ForegroundColor Yellow
                    Add-Content -Path $SimConsoleLog -Value "[21:00:00] $nxtName has been defeated!" -Encoding UTF8
                    Start-Sleep -Seconds 2
                    Write-Host "[OK] O Bot detectou a morte de '$nxtName' e enviou o alerta no Discord!" -ForegroundColor Green
                    Write-Host ""
                    python $ScriptPy summary-line
                } else {
                    Write-Host "[AVISO] Todos os bosses ja foram derrotados na simulacao!" -ForegroundColor Yellow
                }
                Wait-KeyPress
            }
            "6" {
                $target = (Read-Host "Digite o nome ou ID do Boss/Marco para MARCAR (ex: crabulon, lab_planetoid, goblin_army)").Trim()
                if (-not [string]::IsNullOrWhiteSpace($target)) {
                    python $ScriptPy mark "$target"
                }
                Wait-KeyPress
            }
            "7" {
                $target = (Read-Host "Digite o nome ou ID do Boss/Marco para DESMARCAR (ex: shimmer, eye of cthulhu)").Trim()
                if (-not [string]::IsNullOrWhiteSpace($target)) {
                    python $ScriptPy unmark "$target"
                }
                Wait-KeyPress
            }
            "8" {
                $metaTxt = (Read-Host "Digite o texto da nova Meta para criar").Trim()
                if (-not [string]::IsNullOrWhiteSpace($metaTxt)) {
                    python $ScriptPy add-goal "$metaTxt"
                }
                Wait-KeyPress
            }
            "9" {
                Write-Host "--- LOG INTERNO DO BOT NAMELESS DEITY ---" -ForegroundColor Cyan
                if (Test-Path $BotStdoutLog) { Get-Content $BotStdoutLog }
                if (Test-Path $BotStderrLog) { Get-Content $BotStderrLog | ForEach-Object { Write-Host $_ -ForegroundColor Yellow } }
                Wait-KeyPress
            }
            "0" {
                break
            }
            default { }
        }
        if ($opt -eq "0") { break }
    }

} finally {
    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor DarkCyan
    Write-Host " [LIMPEZA] Desfazendo alteracoes de teste e restaurando estado inicial..." -ForegroundColor Cyan

    # 1. Para o processo em background do Bot
    if ($null -ne $BotProcess -and -not $BotProcess.HasExited) {
        Write-Host " -> Encerrando processo isolado do Bot Nameless Deity (PID: $($BotProcess.Id))..." -ForegroundColor Gray
        Stop-Process -Id $BotProcess.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }

    # 2. Apaga do Discord todas as mensagens e embeds enviados durante o teste
    if (Test-Path $SentMessagesRecord) {
        Write-Host " -> Removendo mensagens/embeds de teste enviados no canal do Discord..." -ForegroundColor Gray
        $delOut = python $ScriptPy cleanup-discord-test "$SentMessagesRecord" 2>&1 | Out-String
        if ($delOut -match "DELETED_DISCORD_MESSAGES:(\d+)") {
            Write-Host "    [OK] $($Matches[1]) mensagem(ns) de teste apagada(s) do Discord!" -ForegroundColor Green
        }
    }

    # 3. Restaura arquivos reais de Worlds/
    if (Test-Path $RealWorldsDir) {
        Get-ChildItem -Path $RealWorldsDir -Filter "MundoSimuladoTeste*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        foreach ($pf in $RealProgFiles) {
            $bkpFile = Join-Path $SandboxDir ("backup_real_" + $pf.Name)
            if (Test-Path $bkpFile) {
                Copy-Item $bkpFile $pf.FullName -Force
            }
        }
    }

    # 4. Remove o diretorio Sandbox temporario por completo
    Remove-Item $SandboxDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host " [OK] Ambiente 100% limpo e restaurado ao estado inicial!" -ForegroundColor Green
    Write-Host "==================================================================" -ForegroundColor DarkCyan
    if (-not $AutoExit) {
        Start-Sleep -Seconds 2
    }
}
