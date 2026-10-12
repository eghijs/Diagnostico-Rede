<#
Proprietário, nome: Erik Pereira Ghijs
Contato: eghijs@gmail.com

Organização, projeto: Diagnostico-Rede
Finalidade do script: Coletar somente hostname, MAC Wi-Fi,
MAC da rede cabeada e data da coleta.
Salvar relatório na Área de Trabalho, organizado por data,
sem sobrescrever arquivos existentes.

Ambiente previsto: Windows 10 e Windows 11, Windows PowerShell 5.1.
Classificação: Uso interno, confidencial
Controle de versão: Versão 1.1.0, data 12-10-2026

Aviso legal: Script de propriedade exclusiva do autor.
Uso restrito ao ambiente interno autorizado.
Proibida cópia, redistribuição, modificação ou uso sem autorização formal.
Uso indevido sujeito a sanções legais.

Checklist de segurança: Validação dos adaptadores, MACs e caminhos.
Mensagens de resultado na interface.
Sem logs adicionais para manter somente as informações solicitadas.
Modo DryRun disponível.
Não exige privilégios elevados.
Não altera configurações de rede ou políticas de execução.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'Este diagnóstico requer Windows.'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Resultado = $null
$script:Simulacao = [bool]$DryRun

$areaTrabalho = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::DesktopDirectory
)

if ([string]::IsNullOrWhiteSpace($areaTrabalho)) {
    throw 'Não foi possível localizar a Área de Trabalho.'
}

$script:PastaBase = Join-Path $areaTrabalho 'Diagnostico-Rede'

function ConvertTo-Mac {
    param(
        [AllowNull()]
        [string]$Endereco
    )

    $limpo = $Endereco -replace '[-:\.\s]', ''

    if (
        $limpo -notmatch '^[0-9A-Fa-f]{12}$' -or
        $limpo -in @('000000000000', 'FFFFFFFFFFFF')
    ) {
        return ''
    }

    return (
        [regex]::Matches($limpo.ToUpperInvariant(), '.{2}') |
        ForEach-Object { $_.Value }
    ) -join '-'
}

function Get-NetworkDiagnostic {
    $hostname = [Environment]::MachineName

    if ([string]::IsNullOrWhiteSpace($hostname)) {
        throw 'Não foi possível identificar o hostname.'
    }

    $adaptadores = @(
        Get-CimInstance `
            -Namespace 'root/StandardCimv2' `
            -ClassName 'MSFT_NetAdapter' `
            -Property HardwareInterface, Virtual, InterfaceType,
                NdisPhysicalMedium, NetworkAddresses, InterfaceIndex `
            -OperationTimeoutSec 15 `
            -ErrorAction Stop |
            Sort-Object InterfaceIndex
    )

    $wifi = New-Object 'System.Collections.Generic.List[string]'
    $cabo = New-Object 'System.Collections.Generic.List[string]'

    foreach ($adaptador in $adaptadores) {
        if (
            -not $adaptador.HardwareInterface -or
            $adaptador.Virtual
        ) {
            continue
        }

        $tipo = ''

        if (
            [int]$adaptador.InterfaceType -eq 71 -or
            [int]$adaptador.NdisPhysicalMedium -in @(1, 9)
        ) {
            $tipo = 'Wi-Fi'
        }
        elseif (
            [int]$adaptador.InterfaceType -eq 6 -or
            [int]$adaptador.NdisPhysicalMedium -eq 14
        ) {
            $tipo = 'Cabo'
        }
        else {
            continue
        }

        foreach ($endereco in @($adaptador.NetworkAddresses)) {
            $mac = ConvertTo-Mac ([string]$endereco)

            if ([string]::IsNullOrWhiteSpace($mac)) {
                continue
            }

            if ($tipo -eq 'Wi-Fi') {
                if (-not $wifi.Contains($mac)) {
                    $wifi.Add($mac)
                }
            }
            else {
                if (-not $cabo.Contains($mac)) {
                    $cabo.Add($mac)
                }
            }
        }
    }

    $macWifi = if ($wifi.Count -gt 0) {
        $wifi -join ', '
    }
    else {
        'Não disponível'
    }

    $macCabo = if ($cabo.Count -gt 0) {
        $cabo -join ', '
    }
    else {
        'Não disponível'
    }

    [pscustomobject]@{
        Hostname = $hostname
        MacWifi  = $macWifi
        MacCabo  = $macCabo
        Data     = Get-Date
    }
}

function Format-NetworkDiagnostic {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Resultado
    )

    return @(
        'Hostname: ' + $Resultado.Hostname
        'Mac Wi-Fi: ' + $Resultado.MacWifi
        'Mac Cabo: ' + $Resultado.MacCabo
        'Data da coleta: ' + $Resultado.Data.ToString(
            'dd/MM/yyyy HH:mm:ss'
        )
    ) -join [Environment]::NewLine
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Diagnóstico de Rede, versão 1.1.0'
$form.ClientSize = New-Object System.Drawing.Size(740, 300)
$form.MinimumSize = New-Object System.Drawing.Size(650, 330)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$texto = New-Object System.Windows.Forms.TextBox
$texto.Location = New-Object System.Drawing.Point(20, 20)
$texto.Size = New-Object System.Drawing.Size(700, 175)
$texto.Multiline = $true
$texto.ReadOnly = $true
$texto.ScrollBars = 'Both'
$texto.WordWrap = $false
$texto.Anchor = 'Top, Bottom, Left, Right'
$texto.Font = New-Object System.Drawing.Font('Consolas', 11)
$texto.Text = 'Clique em Coletar.'
$form.Controls.Add($texto)

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(20, 205)
$status.Size = New-Object System.Drawing.Size(700, 35)
$status.Anchor = 'Bottom, Left, Right'

$status.Text = if ($script:Simulacao) {
    'Modo DryRun, nenhuma gravação será realizada.'
}
else {
    'Destino, Área de Trabalho, pasta Diagnostico-Rede.'
}

$form.Controls.Add($status)

$btnColetar = New-Object System.Windows.Forms.Button
$btnColetar.Text = 'Coletar'
$btnColetar.Location = New-Object System.Drawing.Point(20, 250)
$btnColetar.Size = New-Object System.Drawing.Size(130, 32)
$btnColetar.Anchor = 'Bottom, Left'
$form.Controls.Add($btnColetar)

$btnSalvar = New-Object System.Windows.Forms.Button
$btnSalvar.Text = 'Salvar relatório'
$btnSalvar.Location = New-Object System.Drawing.Point(165, 250)
$btnSalvar.Size = New-Object System.Drawing.Size(160, 32)
$btnSalvar.Anchor = 'Bottom, Left'
$btnSalvar.Enabled = $false
$form.Controls.Add($btnSalvar)

$btnFechar = New-Object System.Windows.Forms.Button
$btnFechar.Text = 'Fechar'
$btnFechar.Location = New-Object System.Drawing.Point(590, 250)
$btnFechar.Size = New-Object System.Drawing.Size(130, 32)
$btnFechar.Anchor = 'Bottom, Right'
$form.Controls.Add($btnFechar)

$btnColetar.Add_Click({
    $btnColetar.Enabled = $false
    $btnSalvar.Enabled = $false
    $script:Resultado = $null
    $form.UseWaitCursor = $true
    $status.Text = 'Coletando informações.'
    $form.Refresh()

    try {
        $script:Resultado = Get-NetworkDiagnostic
        $texto.Text = Format-NetworkDiagnostic $script:Resultado
        $status.Text = 'Coleta concluída.'
        $btnSalvar.Enabled = $true
    }
    catch {
        $texto.Text = 'Falha na coleta.' +
            [Environment]::NewLine + $_.Exception.Message

        $status.Text = 'Não foi possível concluir a coleta.'
    }
    finally {
        $form.UseWaitCursor = $false
        $btnColetar.Enabled = $true
    }
})

$btnSalvar.Add_Click({
    if ($null -eq $script:Resultado) {
        return
    }

    $stream = $null
    $arquivoCriado = $false
    $arquivo = $null

    try {
        $pastaDia = Join-Path $script:PastaBase (
            $script:Resultado.Data.ToString('dd-MM-yyyy')
        )

        $nomeSeguro = $script:Resultado.Hostname -replace (
            '[^A-Za-z0-9._-]'
        ), '_'

        if ([string]::IsNullOrWhiteSpace($nomeSeguro)) {
            throw 'Hostname inválido para nome de arquivo.'
        }

        $arquivo = Join-Path $pastaDia ($nomeSeguro + '.txt')

        if ($script:Simulacao) {
            $status.Text = 'DryRun, relatório não gravado.'

            [void][System.Windows.Forms.MessageBox]::Show(
                $form,
                'O relatório seria salvo em ' + $arquivo,
                'Simulação'
            )

            return
        }

        [void][System.IO.Directory]::CreateDirectory($pastaDia)

        if ([System.IO.File]::Exists($arquivo)) {
            $status.Text = 'O arquivo já existe e foi preservado.'

            [void][System.Windows.Forms.MessageBox]::Show(
                $form,
                'O relatório já existe e não será sobrescrito.' +
                    [Environment]::NewLine + $arquivo,
                'Relatório existente'
            )

            return
        }

        $conteudo = Format-NetworkDiagnostic $script:Resultado
        $utf8 = New-Object System.Text.UTF8Encoding($true)

        $bytes = $utf8.GetPreamble() + $utf8.GetBytes(
            $conteudo + [Environment]::NewLine
        )

        $stream = [System.IO.File]::Open(
            $arquivo,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )

        $arquivoCriado = $true
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Dispose()
        $stream = $null
        $arquivoCriado = $false

        $status.Text = 'Relatório salvo na Área de Trabalho.'

        [void][System.Windows.Forms.MessageBox]::Show(
            $form,
            'Relatório salvo em ' + $arquivo,
            'Gravação concluída'
        )
    }
    catch {
        $erroGravacao = $_.Exception.Message

        if ($null -ne $stream) {
            $stream.Dispose()
            $stream = $null
        }

        if ($arquivoCriado -and $null -ne $arquivo) {
            try {
                [System.IO.File]::Delete($arquivo)
            }
            catch {
                $erroGravacao += (
                    [Environment]::NewLine +
                    'Não foi possível remover o arquivo incompleto.'
                )
            }
        }

        $status.Text = 'Não foi possível salvar o relatório.'

        [void][System.Windows.Forms.MessageBox]::Show(
            $form,
            $erroGravacao,
            'Falha na gravação'
        )
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
})

$btnFechar.Add_Click({
    $form.Close()
})

try {
    [void]$form.ShowDialog()
}
finally {
    $form.Dispose()
}
