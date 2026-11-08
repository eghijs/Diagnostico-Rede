<#
Proprietário, nome: Erik Pereira Ghijs
Contato: eghijs@gmail.com

Organização, projeto: Controle Local de Segurança para Notebooks Windows
Finalidade do script: Bloquear Hotspot, ICS, compartilhamento de internet, Hosted Network e Bluetooth PAN em notebooks Windows 10 e Windows 11 sem dependência de AD ou GPO de domínio.
Ambiente previsto: Windows 10 e Windows 11, execução local como administrador ou empacotado em .exe com elevação administrativa.
Classificação: Uso interno, confidencial
Controle de versão: Versão 2.1.0, data 09-07-2026

Aviso legal: Script de propriedade exclusiva do autor. Uso restrito ao ambiente interno autorizado. Proibida cópia, redistribuição, modificação ou uso sem autorização formal. Uso indevido sujeito a sanções legais.

Checklist de segurança: validações, logs, modo dry-run quando aplicável, backup de configurações, execução com privilégios elevados, bloqueio de serviços críticos de compartilhamento e atenção à execução com privilégios elevados.
#>

param(
    [ValidateSet("Bloquear", "Restaurar", "Status")]
    [string]$Acao = "Bloquear",

    [switch]$DryRun
)

$ErrorActionPreference = "SilentlyContinue"

$BaseDir = "C:\TI"
$LogDir = "$BaseDir\Logs"
$BackupDir = "$BaseDir\Backup"
$LogFile = "$LogDir\bloqueio_hotspot_windows_v2_1.log"

function New-Dir {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        if (-not $DryRun) {
            New-Item -Path $Path -ItemType Directory -Force | Out-Null
        }
    }
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "$Timestamp [$Level] $Message"

    if (-not $DryRun) {
        Add-Content -Path $LogFile -Value $Line -Encoding UTF8
    }
}

function Test-Admin {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-AsAdmin {
    if (-not (Test-Admin)) {
        $CurrentFile = $MyInvocation.MyCommand.Path

        if ($CurrentFile) {
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$CurrentFile`" -Acao $Acao" -Verb RunAs
            exit
        }
    }
}

function Invoke-Safe {
    param(
        [string]$Description,
        [scriptblock]$Command
    )

    Write-Log $Description

    if ($DryRun) {
        Write-Log "DryRun ativo, comando não executado: $Description" "DRYRUN"
        return
    }

    try {
        & $Command
        Write-Log "OK: $Description"
    }
    catch {
        Write-Log "ERRO: $Description, $($_.Exception.Message)" "ERRO"
    }
}

function Set-RegDword {
    param(
        [string]$Path,
        [string]$Name,
        [int]$Value
    )

    Invoke-Safe "Registro, $Path, $Name = $Value" {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }

        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
    }
}

function Remove-RegValue {
    param(
        [string]$Path,
        [string]$Name
    )

    Invoke-Safe "Removendo registro, $Path, $Name" {
        if (Test-Path $Path) {
            Remove-ItemProperty -Path $Path -Name $Name -Force
        }
    }
}

function Backup-Registry {
    Invoke-Safe "Backup das chaves de registro" {
        reg export "HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess" "$BackupDir\sharedaccess_service.reg" /y | Out-Null
        reg export "HKLM\SYSTEM\CurrentControlSet\Services\icssvc" "$BackupDir\icssvc_service.reg" /y | Out-Null
        reg export "HKLM\SOFTWARE\Microsoft\WcmSvc\Tethering" "$BackupDir\tethering.reg" /y | Out-Null
    }
}

function Disable-ServiceLocal {
    param([string]$Name)

    Invoke-Safe "Parando serviço $Name" {
        Stop-Service -Name $Name -Force
    }

    Invoke-Safe "Desabilitando serviço $Name" {
        Set-Service -Name $Name -StartupType Disabled
    }
}

function Restore-ServiceLocal {
    param([string]$Name)

    Invoke-Safe "Restaurando serviço $Name para Manual" {
        Set-Service -Name $Name -StartupType Manual
    }
}

function Disable-Hotspot {
    Write-Log "Iniciando bloqueio do Hotspot Windows."

    Backup-Registry

    Disable-ServiceLocal "SharedAccess"
    Disable-ServiceLocal "icssvc"

    Invoke-Safe "Parando Hosted Network" {
        netsh wlan stop hostednetwork | Out-Null
    }

    Invoke-Safe "Bloqueando Hosted Network" {
        netsh wlan set hostednetwork mode=disallow | Out-Null
    }

    $BluetoothAdapters = Get-NetAdapter | Where-Object {
        $_.Name -like "*Bluetooth*" -or
        $_.InterfaceDescription -like "*Bluetooth*"
    }

    foreach ($Adapter in $BluetoothAdapters) {
        Invoke-Safe "Desabilitando Bluetooth PAN, $($Adapter.Name)" {
            Disable-NetAdapter -Name $Adapter.Name -Confirm:$false
        }
    }

    Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess" "Start" 4
    Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Services\icssvc" "Start" 4
    Set-RegDword "HKLM:\SOFTWARE\Microsoft\WcmSvc\Tethering" "EntitlementEnabled" 0
    Set-RegDword "HKLM:\SOFTWARE\Microsoft\WcmSvc\Tethering" "TetheringDisabled" 1

    Write-Log "Bloqueio concluído."
}

function Restore-Hotspot {
    Write-Log "Iniciando restauração do Hotspot Windows."

    Restore-ServiceLocal "SharedAccess"
    Restore-ServiceLocal "icssvc"

    Invoke-Safe "Liberando Hosted Network" {
        netsh wlan set hostednetwork mode=allow | Out-Null
    }

    $BluetoothAdapters = Get-NetAdapter | Where-Object {
        $_.Name -like "*Bluetooth*" -or
        $_.InterfaceDescription -like "*Bluetooth*"
    }

    foreach ($Adapter in $BluetoothAdapters) {
        Invoke-Safe "Reabilitando Bluetooth PAN, $($Adapter.Name)" {
            Enable-NetAdapter -Name $Adapter.Name -Confirm:$false
        }
    }

    Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess" "Start" 3
    Set-RegDword "HKLM:\SYSTEM\CurrentControlSet\Services\icssvc" "Start" 3

    Remove-RegValue "HKLM:\SOFTWARE\Microsoft\WcmSvc\Tethering" "EntitlementEnabled"
    Remove-RegValue "HKLM:\SOFTWARE\Microsoft\WcmSvc\Tethering" "TetheringDisabled"

    Write-Log "Restauração concluída."
}

function Show-Status {
    Write-Log "Consultando status."

    $SharedAccess = Get-Service -Name "SharedAccess"
    $IcsSvc = Get-Service -Name "icssvc"

    Write-Log "SharedAccess, status: $($SharedAccess.Status)"
    Write-Log "icssvc, status: $($IcsSvc.Status)"

    $SharedAccessStart = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess" -Name Start
    $IcsSvcStart = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\icssvc" -Name Start

    Write-Log "SharedAccess, Start: $($SharedAccessStart.Start)"
    Write-Log "icssvc, Start: $($IcsSvcStart.Start)"
}

Restart-AsAdmin

New-Dir $BaseDir
New-Dir $LogDir
New-Dir $BackupDir

Write-Log "============================================================"
Write-Log "Bloquear Hotspot Windows v2.1 iniciado. Ação: $Acao. DryRun: $DryRun."

switch ($Acao) {
    "Bloquear" {
        Disable-Hotspot
    }

    "Restaurar" {
        Restore-Hotspot
    }

    "Status" {
        Show-Status
    }
}

Write-Log "Bloquear Hotspot Windows v2.1 finalizado."
Write-Log "============================================================"