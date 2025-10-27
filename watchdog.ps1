# Define o diretório onde o script está localizado
$script:ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configFile = Join-Path -Path $script:ScriptDirectory -ChildPath "config.json"

# O $script:scriptLogPath será definido após o JSON carregar.
$script:tempLogPath = Join-Path -Path $PSScriptRoot -ChildPath "watchdog_init.log"
function Write-LogEntry {
    param ([string]$Level, [string]$Message)
    $logEntry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] - [$Level] - $Message"
    Write-Host $logEntry
    
    if ($script:scriptLogPath) {
        Add-Content -Path $script:scriptLogPath -Value $logEntry
    } else {
        Add-Content -Path $script:tempLogPath -Value $logEntry
    }
}
function Write-Log { param([string]$Message) Write-LogEntry "INFO" $Message }
function Write-Warn { param([string]$Message) Write-LogEntry "ALERTA" $Message }
function Write-Error { param([string]$Message) Write-LogEntry "ERRO" $Message }

# Carrega a configuração do arquivo JSON
if (-not (Test-Path $configFile)) {
    Write-Error "CRÍTICO: 'config.json' não encontrado em '$script:ScriptDirectory'. Saindo." # Mensagem de erro mais específica
    exit 1
}
try {
    $script:Config = Get-Content -Raw -Path $configFile | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Error "CRÍTICO: Falha ao carregar 'config.json'. Verifique a sintaxe. Erro: $($_.Exception.Message). Saindo."
    exit 1
}

# Define as variáveis globais a partir do arquivo config.json

# Serviço a ser monitorado
$script:serviceName = $Config.ServiceMonitor.ServiceName
$script:pendingThreshold = $Config.ServiceMonitor.Thresholds.Warning
$script:emergencyThreshold = $Config.ServiceMonitor.Thresholds.Emergency
$script:cooldownMinutes = $Config.ServiceMonitor.CooldownMinutes
$script:checkIntervalSeconds = $Config.ServiceMonitor.CheckIntervalSeconds

# Banco de Dados
$script:connectionString = $Config.Database.ConnectionString
$script:sqlTriggerQuery = $Config.Database.Query_Trigger
$script:sqlDiagnosticQuery = $Config.Database.Query_Diagnostic

# Alertas por E-mail
$script:sendEmailAlerts = $Config.Alerting.SendEmail
$script:emailTo = $Config.Alerting.EmailTo
$script:emailFrom = $Config.Alerting.EmailFrom
$script:gmailUser = $Config.Alerting.EmailUser
$script:gmailAppPassword = $Config.Alerting.AppPassword
$script:smtpServer = $Config.Alerting.SmtpServer
$script:smtpPort = $Config.Alerting.SmtpPort
$script:emailSubject = $Config.Alerting.Subject_Alert.Replace("{ServiceName}", $script:serviceName)
$script:emailSubject_Resolved = $Config.Alerting.Subject_Resolved.Replace("{ServiceName}", $script:serviceName)

# Logs
$script:logDirectory = Join-Path -Path $script:ScriptDirectory -ChildPath $Config.Logging.LogDirectory # Usa a nova variável
$script:logRetentionDays = $Config.Logging.LogRetentionDays
$script:logDate = (Get-Date -Format 'ddMMyy')
$script:scriptLogPath = Join-Path -Path $script:logDirectory -ChildPath "watchdog_log_$($script:logDate).log"

# Flag
$script:cooldownFlagFile = Join-Path -Path $script:ScriptDirectory -ChildPath "watchdog.cooldown" # Usa a nova variável
$script:alertSentFlagFile = Join-Path -Path $script:ScriptDirectory -ChildPath "watchdog.alert_sent" # Usa a nova variável

# Garante que o diretório de log exista
if (-not (Test-Path $script:logDirectory)) {
    New-Item -ItemType Directory -Path $script:logDirectory | Out-Null
}
Write-Log "Configuração carregada com sucesso."

# Carrega o driver de DB (Ex: Oracle 32-bit)
try {
    [System.Reflection.Assembly]::LoadWithPartialName("System.Data.OracleClient") | Out-Null
    Write-Log "Driver de banco de dados (System.Data.OracleClient) carregado."
}
catch {
    Write-Error "CRÍTICO: Falha ao carregar driver de banco de dados (System.Data.OracleClient). O driver .NET correto deve estar instalado. Saindo."
    exit 1
}

# Gerencia a rotação de logs
function Invoke-LogRotation { # <-- MUDANÇA: Nome da função
    try {
        Write-Log "Iniciando rotação de logs (retenção: $script:logRetentionDays dias)..."
        $oldLogs = Get-ChildItem -Path $script:logDirectory -Filter "*.log" | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$script:logRetentionDays) }
        if ($oldLogs) {
            foreach ($log in $oldLogs) {
                Write-Log "Removendo log antigo: $($log.Name)"
                Remove-Item -Path $log.FullName -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Log "Nenhum log antigo encontrado."
        }
    }
    catch {
        Write-Warn "Falha ao executar rotação de logs: $($_.Exception.Message)"
    }
}

# Envia o e-mail de ALERTA
function Send-EscalationEmail {
    param ([int]$CurrentQueueCount, [datetime]$LastRestartTime, [string]$DiagnosticData, [System.Management.Automation.PSCredential]$Credential)
    
    Write-Warn "Montando e-mail de escalonamento para $script:emailTo..."
    $endTime = $LastRestartTime.AddMinutes($script:cooldownMinutes)
    $diagHtml = "<pre style='font-family: Consolas, Monospace; font-size: 12px;'>$DiagnosticData</pre>"
    
    $emailBody = @"
<body style='font-family: Arial, sans-serif; font-size: 14px;'>
<p><b>Atenção,</b></p>
<p>O script watchdog detectou que a fila de tarefas pendentes para o serviço <b>$($script:serviceName)</b> continua alta, mesmo após uma tentativa de reinício.</p>
<p>A automação está em período de 'cooldown' e <b>NÃO tentará reiniciar o serviço</b> novamente até que o período termine.</p>
<p>É necessária uma investigação manual para verificar por que o serviço não está processando a fila.</p>
<hr>
<h3 style='color: #D9534F;'>Status da Fila (Gatilho)</h3>
<ul>
    <li><b>Servidor:</b> $($env:COMPUTERNAME)</li>
    <li><b>Tarefas Pendentes:</b> <span style='color: #D9534F; font-weight: bold;'>$CurrentQueueCount</span></li>
    <li><b>Limite de Alerta:</b> $script:pendingThreshold</li>
</ul>
<hr>
<h3 style='color: #F0AD4E;'>Informações do Cooldown</h3>
<ul>
    <li><b>Último Reinício Automático:</b> $LastRestartTime</li>
    <li><b>Fim do Cooldown (Próxima Ação):</b> $endTime</li>
</ul>
<hr>
<h3>Diagnóstico: Status Atual das Tarefas (Snapshot)</h3>
$diagHtml
<hr>
</body>
"@

    try {
        Send-MailMessage -To $script:emailTo -From $script:emailFrom -Subject $script:emailSubject -SmtpServer $script:smtpServer -Port $script:smtpPort -Body $emailBody -BodyAsHtml -Priority High -UseSsl -Credential $Credential -ErrorAction Stop -Encoding ([System.Text.Encoding]::UTF8)
        Write-Log "Sucesso: E-mail de escalonamento enviado."
    }
    catch {
        Write-Error "Falha ao enviar e-mail de escalonamento: $($_.Exception.Message -replace "`n", " ")"
    }
}

# Envia o e-mail de RESOLUÇÃO
function Send-ResolutionEmail {
    param ([int]$CurrentQueueCount, [System.Management.Automation.PSCredential]$Credential)
    
    Write-Warn "Montando e-mail de resolução para $script:emailTo..."
    
    $emailBody = @"
<body style='font-family: Arial, sans-serif; font-size: 14px;'>
<p><b>Este problema foi resolvido. Ação manual não é mais necessária.</b></p>
<p>Este é um acompanhamento do alerta anterior. O script watchdog detectou que a fila de tarefas pendentes foi processada e está agora em um nível normal.</p>
<hr>
<h3 style='color: #28A745;'>Status da Fila (Resolvido)</h3>
<ul>
    <li><b>Servidor:</b> $($env:COMPUTERNAME)</li>
    <li><b>Tarefas Pendentes Atuais:</b> <span style='color: #28A745; font-weight: bold;'>$CurrentQueueCount</span></li>
    <li><b>Limite de Alerta:</b> $script:pendingThreshold</li>
</ul>
<hr>
<p>O sistema se recuperou automaticamente.</p>
</body>
"@

    try {
        Send-MailMessage -To $script:emailTo -From $script:emailFrom -Subject $script:emailSubject_Resolved -SmtpServer $script:smtpServer -Port $script:smtpPort -Body $emailBody -BodyAsHtml -Priority High -UseSsl -Credential $Credential -ErrorAction Stop -Encoding ([System.Text.Encoding]::UTF8)
        Write-Log "Sucesso: E-mail de resolução enviado."
    }
    catch {
        Write-Error "Falha ao enviar e-mail de resolução: $($_.Exception.Message -replace "`n", " ")"
    }
}


# ================= LÓGICA PRINCIPAL (Watchdog) =================

# 0. Rotação de Logs
Invoke-LogRotation #

# 1. Verificação de Cooldown. Se o arquivo .cooldown existir, o script entra em modo de alerta, não de correção.
if (Test-Path $script:cooldownFlagFile) {
    $lastRestartTime = (Get-Item $script:cooldownFlagFile).LastWriteTime
    $timeSinceLastRestart = (Get-Date) - $lastRestartTime
    
    # Se o Cooldown estiver ativo
    if ($timeSinceLastRestart.TotalMinutes -lt $script:cooldownMinutes) {
        Write-Warn "Em período de cooldown (reinício em: $lastRestartTime)."
        
        $connection = $null
        $pendingDocCount = 0
        $diagResultString = "Falha ao obter diagnóstico."
        $alertSentFileExists = Test-Path $script:alertSentFlagFile 

        try {
            $connection = New-Object System.Data.OracleClient.OracleConnection($script:connectionString)
            $connection.Open()
            $command = New-Object System.Data.OracleClient.OracleCommand($script:sqlTriggerQuery, $connection)
            $pendingDocCount = [int]$command.ExecuteScalar()
            Write-Log "OK: Verificação (em cooldown) da fila: $pendingDocCount pendentes."

            # Cenário A: Fila continua alta, mas o alerta ainda não foi enviado.
            if ($pendingDocCount -gt $script:pendingThreshold) {
                if ($alertSentFileExists) {
                    Write-Log "Fila continua alta ($pendingDocCount), mas o e-mail de alerta já foi enviado. Suprimindo novo alerta."
                } else {
                    Write-Error "ESCALONAMENTO: Fila ALTA ($pendingDocCount) durante o cooldown. Disparando alerta."
                    
                    $commandDiag = New-Object System.Data.OracleClient.OracleCommand($script:sqlDiagnosticQuery, $connection)
                    $adapter = New-Object System.Data.OracleClient.OracleDataAdapter($commandDiag)
                    $dataSet = New-Object System.Data.DataSet
                    $adapter.Fill($dataSet) | Out-Null
                    $diagResultString = $dataSet.Tables[0] | Format-Table -AutoSize | Out-String
                    
                    if ($script:sendEmailAlerts) {
                        $securePassword = ConvertTo-SecureString $script:gmailAppPassword -AsPlainText -Force
                        $credential = New-Object System.Management.Automation.PSCredential ($script:gmailUser, $securePassword)
                        
                        Send-EscalationEmail -CurrentQueueCount $pendingDocCount -LastRestartTime $lastRestartTime -DiagnosticData $diagResultString -Credential $credential
                        Set-Content -Path $script:alertSentFlagFile -Value (Get-Date -Format 'o')
                    } else {
                        Write-Warn "E-mails de alerta desabilitados ('SendEmail' = 'false')."
                    }
                }
            # Cenário B: Fila normalizou. Envia e-mail de resolução e limpa a flag
            } else {
                if ($alertSentFileExists) {
                    Write-Log "RESOLVIDO: Fila normalizou ($pendingDocCount). Enviando e-mail de resolução."
                    
                    if ($script:sendEmailAlerts) {
                        $securePassword = ConvertTo-SecureString $script:gmailAppPassword -AsPlainText -Force
                        $credential = New-Object System.Management.Automation.PSCredential ($script:gmailUser, $securePassword)
                        
                        Send-ResolutionEmail -CurrentQueueCount $pendingDocCount -Credential $credential
                    }
                    Remove-Item $script:alertSentFlagFile -ErrorAction SilentlyContinue
                } else {
                    Write-Log "OK: Em cooldown, fila baixa ($pendingDocCount). Serviço recuperado."
                }
            }
        }
        catch {
            Write-Error "Falha ao checar o DB durante o cooldown: $($_.Exception.Message -replace "`n", " ")"
        }
        finally {
            if ($connection -and $connection.State -eq 'Open') { $connection.Close() }
        }
        
        Write-Log "Script finalizado (Modo Cooldown)."
        exit
    
    # Cenário C: Cooldown expirou. Limpa as flags e volta ao monitoramento normal
    } else {
        Write-Log "Período de cooldown expirou. Removendo flags e continuando checagem normal."
        Remove-Item $script:cooldownFlagFile -ErrorAction SilentlyContinue
        Remove-Item $script:alertSentFlagFile -ErrorAction SilentlyContinue
    }
}

# 2. Checagem de Serviço
Write-Log "Iniciando verificação de serviço..."
$problemDetected_Queue = $false
$serviceStatus = ""

try {
    $service = Get-Service -Name $script:serviceName -ErrorAction Stop
    $serviceStatus = $service.Status
    
    if ($serviceStatus -eq 'Stopped' -or $serviceStatus -eq 'Paused') {
        Write-Warn "Serviço '$script:serviceName' está $serviceStatus. Tentando iniciar..."
        try {
            Start-Service -Name $script:serviceName -ErrorAction Stop
            Write-Log "Sucesso: Serviço '$script:serviceName' iniciado."
            $serviceStatus = (Get-Service -Name $script:serviceName).Status
        }
        catch {
            Write-Error "Falha ao INICIAR serviço '$script:serviceName'. $($_.Exception.Message -replace "`n", " ")"
        }
    } elseif ($serviceStatus -eq 'Running') {
        Write-Log "OK: Serviço '$script:serviceName' está 'Running'."
    } else {
        Write-Log "INFO: Serviço '$script:serviceName' está em estado de transição ($serviceStatus)."
    }
}
catch {
    Write-Error "CRÍTICO: Serviço '$script:serviceName' não encontrado. Verifique o nome. Script abortado."
    exit 1
}

# 3. Checagem da Fila no Banco de Dados
if ($serviceStatus -eq 'Running') {
    $connection = $null 
    try {
        $connection = New-Object System.Data.OracleClient.OracleConnection($script:connectionString)
        $connection.Open()
        $command = New-Object System.Data.OracleClient.OracleCommand($script:sqlTriggerQuery, $connection)
        
        # Primeira Verificação
        $pendingDocCount = [int]$command.ExecuteScalar()
        Write-Log "OK: Verificação da fila concluída. Tarefas pendentes: $pendingDocCount"
        
        if ($pendingDocCount -gt $script:pendingThreshold) {
            
            # Verificação de Emergência (ação imediata)
            if ($pendingDocCount -ge $script:emergencyThreshold) {
                Write-Error "EMERGÊNCIA: Fila ($pendingDocCount) atingiu/excedeu limite ($script:emergencyThreshold). Ação imediata."
                $problemDetected_Queue = $true
            } else {
                # Verificação Nível 1 (aguarda X segundos para confirmar)
                Write-Warn "NÍVEL 1: Fila ($pendingDocCount) alta. Re-checando em $script:checkIntervalSeconds segundos..."
                $connection.Close() 
                Start-Sleep -Seconds $script:checkIntervalSeconds
                
                Write-Log "Executando segunda verificação da fila..."
                $connection.Open() 
                $pendingDocCount_Check2 = [int]$command.ExecuteScalar()
                Write-Log "OK: Segunda verificação. Tarefas pendentes: $pendingDocCount_Check2"
                
                if ($pendingDocCount_Check2 -gt $script:pendingThreshold) {
                    Write-Error "NÍVEL 2: Fila ($pendingDocCount_Check2) continua alta. Travamento confirmado."
                    $problemDetected_Queue = $true
                } else {
                    Write-Log "OK: Fila normalizada ($pendingDocCount_Check2). Pico transiente. Nenhuma ação necessária."
                    $problemDetected_Queue = $false
                }
            }
        }
    }
    catch {
        $errorMessage = $_.Exception.Message -replace "`n", " "
        Write-Error "CRÍTICO: Falha ao consultar banco de dados: $errorMessage"
    }
    finally {
        if ($connection -and $connection.State -eq 'Open') {
            $connection.Close()
        }
    }
} else {
    Write-Log "Verificação da fila pulada (serviço não está 'Running')."
}

# 4. Ação de Correção
if ($problemDetected_Queue) {
    Write-Warn "PROBLEMA CONFIRMADO. Iniciando reinício de serviço..."
    try {
        Restart-Service -Name $script:serviceName -Force -ErrorAction Stop
        Write-Warn "Sucesso: Serviço '$script:serviceName' foi reiniciado."
        
        # Cria o arquivo-flag de cooldown
        Set-Content -Path $script:cooldownFlagFile -Value (Get-Date -Format 'o')
        Write-Log "Flag de cooldown criada. Monitoramento pausado por $script:cooldownMinutes minutos."
    }
    catch {
        Write-Error "Falha ao REINICIAR serviço: $($_.Exception.Message -replace "`n", " ")"
    }
}

Write-Log "Script finalizado."

