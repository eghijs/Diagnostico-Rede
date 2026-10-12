<#
Proprietário, nome: Erik Pereira Ghijs
Contato: eghijs@gmail.com

Organização, projeto: Diagnostico-Rede
Finalidade do script: Coletar hostname e MAC de interfaces físicas Wi-Fi
e Ethernet, exibir os resultados e salvar relatório sem sobrescrever.
Ambiente previsto: Windows 10 e Windows 11, Windows PowerShell 5.1.
Classificação: Uso interno, confidencial
Controle de versão: Versão 1.0.0, data 12-10-2026

Aviso legal: Script de propriedade exclusiva do autor.
Uso restrito ao ambiente interno autorizado.
Proibida cópia, redistribuição, modificação ou uso sem autorização formal.
Uso indevido sujeito a sanções legais.

Checklist de segurança: Validação dos adaptadores e dos caminhos.
Logs locais sem credenciais. Modo DryRun disponível.
Não exige privilégios elevados e não altera configurações de rede.
A publicação deste código deve ocorrer com autorização do proprietário.
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
$script:ModoDryRun = [bool]$DryRun

$documentos = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::MyDocuments
)

if ([string]::IsNullOrWhiteSpace($documentos)) {
    $documentos = $env:LOCALAPPDATA
}

if ([string]::IsNullOrWhiteSpace($documentos)) {
    throw 'Não foi possível localizar uma pasta para os relatórios.'
}

$script:PastaBase = Join-Path $documentos 'Diagnostico-Rede'

function Write-DiagnosticLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mensagem
    )

    if ($script:ModoDryRun) {
        return
    }

    try {
        $pastaLogs = Join-Path $script:PastaBase 'Logs'
        [void][System.IO.Directory]::CreateDirectory($pastaLogs)

        $arquivoLog = Join-Path $pastaLogs (
            '{0}.log' -f (Get-Date -Format 'dd-MM-yyyy')
        )

        $linha = '{0}  {1}{2}' -f (
            Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        ), $Mensagem, [Environment]::NewLine

        $utf8 = New-Object System.Text.UTF8Encoding($true)

        [System.IO.File]::AppendAllText(
            $arquivoLog,
            $linha,
            $utf8
        )
    }
    catch {
        # Falha de log não interrompe a consulta de rede.
        [System.Diagnostics.Debug]::WriteLine($_.Exception.Message)
    }
}

function Get-NetworkDiagnostic {
    $hostname = [Environment]::MachineName

    if ([string]::IsNullOrWhiteSpace($hostname)) {
        throw 'Não foi possível identificar o hostname.'
    }

    # Consulta todas as interfaces, inclusive as desconectadas.
    $adaptadores = @(
        Get-CimInstance `
            -Namespace 'root/StandardCimv2' `
            -ClassName 'MSFT_NetAdapter' `
            -ErrorAction Stop
    )

    $interfaces = @(
        foreach ($adaptador in $adaptadores) {
            if (
                -not $adaptador.HardwareInterface -or
                $adaptador.Virtual
            ) {
                continue
            }

            $tipo = 'Outra interface física'

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

            $macBruto = [string]$adaptador.MacAddress
            $macLimpo = $macBruto -replace '[-:\.\s]', ''
            $macAtual = 'Não disponível'

            if (
                $macLimpo -match '^[0-9A-Fa-f]{12}$' -and
                $macLimpo -ne '000000000000' -and
                $macLimpo -ne 'FFFFFFFFFFFF'
            ) {
                $macAtual = (
                    [regex]::Matches(
                        $macLimpo.ToUpperInvariant(),
                        '.{2}'
                    ) |
                    ForEach-Object { $_.Value }
                ) -join '-'
            }

            $permanenteBruto = [string]$adaptador.PermanentAddress
            $permanenteLimpo = $permanenteBruto -replace '[-:\.\s]', ''
            $macPermanente = 'Não informado pelo driver'

            if (
                $permanenteLimpo -match '^[0-9A-Fa-f]{12}$' -and
                $permanenteLimpo -ne '000000000000' -and
                $permanenteLimpo -ne 'FFFFFFFFFFFF'
            ) {
                $macPermanente = (
                    [regex]::Matches(
                        $permanenteLimpo.ToUpperInvariant(),
                        '.{2}'
                    ) |
                    ForEach-Object { $_.Value }
                ) -join '-'
            }

            $estado = switch ([int]$adaptador.MediaConnectState) {
                1 { 'Conectado' }
                2 { 'Desconectado' }
                default { 'Não informado' }
            }

            [pscustomobject]@{
                Tipo          = $tipo
                Nome          = [string]$adaptador.Name
                Descricao     = [string]$adaptador.InterfaceDescription
                Estado        = $estado
                MacAtual      = $macAtual
                MacPermanente = $macPermanente
                Indice        = [uint32]$adaptador.InterfaceIndex
            }
        }
    )

    [pscustomobject]@{
        Hostname   = $hostname
        Data       = Get-Date
        Interfaces = @($interfaces | Sort-Object Tipo, Indice)
    }
}

function Format-NetworkDiagnostic {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Resultado
    )

    $wifi = @(
        $Resultado.Interfaces |
        Where-Object { $_.Tipo -eq 'Wi-Fi' }
    )

    $cabo = @(
        $Resultado.Interfaces |
        Where-Object { $_.Tipo -eq 'Cabo' }
    )

    $resumoWifi = if ($wifi.Count -gt 0) {
        ($wifi | ForEach-Object { $_.MacAtual }) -join ', '
    }
    else {
        'Nenhum adaptador identificado'
    }

    $resumoCabo = if ($cabo.Count -gt 0) {
        ($cabo | ForEach-Object { $_.MacAtual }) -join ', '
    }
    else {
        'Nenhum adaptador identificado'
    }

    $linhas = New-Object 'System.Collections.Generic.List[string]'

    $linhas.Add('DIAGNÓSTICO DE REDE')
    $linhas.Add('Versão 1.0.0')
    $linhas.Add('')
    $linhas.Add('Hostname: ' + $Resultado.Hostname)
    $linhas.Add('Mac Wi-Fi: ' + $resumoWifi)
    $linhas.Add('Mac Cabo: ' + $resumoCabo)
    $linhas.Add(
        'Data da coleta: ' +
        $Resultado.Data.ToString('dd/MM/yyyy HH:mm:ss')
    )
    $linhas.Add('')
    $linhas.Add('DETALHAMENTO DOS ADAPTADORES FÍSICOS')
    $linhas.Add('')

    if ($Resultado.Interfaces.Count -eq 0) {
        $linhas.Add('Nenhum adaptador físico identificado.')
    }

    foreach ($interface in $Resultado.Interfaces) {
        $linhas.Add('Tipo: ' + $interface.Tipo)
        $linhas.Add('Nome: ' + $interface.Nome)
        $linhas.Add('Descrição: ' + $interface.Descricao)
        $linhas.Add('Estado: ' + $interface.Estado)
        $linhas.Add('MAC atual: ' + $interface.MacAtual)
        $linhas.Add('MAC permanente: ' + $interface.MacPermanente)
        $linhas.Add('')
    }

    $linhas.Add(
        'O MAC atual pode diferir do permanente por randomização ' +
        'do Wi-Fi ou configuração do adaptador.'
    )
    $linhas.Add(
        'A classificação e o MAC permanente dependem das ' +
        'informações disponibilizadas pelo driver.'
    )

    return $linhas -join [Environment]::NewLine
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Diagnóstico de Rede, versão 1.0.0'
$form.Size = New-Object System.Drawing.Size(800, 620)
$form.MinimumSize = New-Object System.Drawing.Size(680, 480)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$titulo = New-Object System.Windows.Forms.Label
$titulo.Text = 'Hostname e MAC dos adaptadores físicos'
$titulo.Location = New-Object System.Drawing.Point(20, 15)
$titulo.Size = New-Object System.Drawing.Size(740, 30)
$titulo.Anchor = 'Top, Left, Right'
$titulo.Font = New-Object System.Drawing.Font(
    'Segoe UI',
    12,
    [System.Drawing.FontStyle]::Bold
)
$form.Controls.Add($titulo)

$texto = New-Object System.Windows.Forms.TextBox
$texto.Location = New-Object System.Drawing.Point(20, 55)
$texto.Size = New-Object System.Drawing.Size(744, 425)
$texto.Multiline = $true
$texto.ReadOnly = $true
$texto.ScrollBars = 'Both'
$texto.WordWrap = $false
$texto.Anchor = 'Top, Bottom, Left, Right'
$texto.Font = New-Object System.Drawing.Font('Consolas', 10)
$texto.Text = 'Clique em Coletar para iniciar o diagnóstico.'
$form.Controls.Add($texto)

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(20, 490)
$status.Size = New-Object System.Drawing.Size(744, 35)
$status.Anchor = 'Bottom, Left, Right'
$status.Text = if ($script:ModoDryRun) {
    'Modo DryRun, nenhuma gravação será realizada.'
}
else {
    'Pronto para coletar.'
}
$form.Controls.Add($status)

$btnColetar = New-Object System.Windows.Forms.Button
$btnColetar.Text = 'Coletar'
$btnColetar.Location = New-Object System.Drawing.Point(20, 535)
$btnColetar.Size = New-Object System.Drawing.Size(130, 32)
$btnColetar.Anchor = 'Bottom, Left'
$form.Controls.Add($btnColetar)

$btnSalvar = New-Object System.Windows.Forms.Button
$btnSalvar.Text = 'Salvar relatório'
$btnSalvar.Location = New-Object System.Drawing.Point(165, 535)
$btnSalvar.Size = New-Object System.Drawing.Size(155, 32)
$btnSalvar.Anchor = 'Bottom, Left'
$btnSalvar.Enabled = $false
$form.Controls.Add($btnSalvar)

$btnFechar = New-Object System.Windows.Forms.Button
$btnFechar.Text = 'Fechar'
$btnFechar.Location = New-Object System.Drawing.Point(634, 535)
$btnFechar.Size = New-Object System.Drawing.Size(130, 32)
$btnFechar.Anchor = 'Bottom, Right'
$form.Controls.Add($btnFechar)

$btnColetar.Add_Click({
    $btnColetar.Enabled = $false
    $btnSalvar.Enabled = $false
    $script:Resultado = $null
    $form.UseWaitCursor = $true
    $status.Text = 'Consultando os adaptadores de rede.'
    $form.Refresh()

    try {
        $script:Resultado = Get-NetworkDiagnostic
        $texto.Text = Format-NetworkDiagnostic $script:Resultado

        $quantidade = $script:Resultado.Interfaces.Count

        $status.Text = (
            'Coleta concluída. Adaptadores físicos encontrados, {0}.' -f
            $quantidade
        )

        $btnSalvar.Enabled = $true

        Write-DiagnosticLog (
            'Coleta concluída. Hostname, {0}. Adaptadores, {1}.' -f
            $script:Resultado.Hostname,
            $quantidade
        )
    }
    catch {
        $texto.Text = 'Falha na coleta.' +
            [Environment]::NewLine +
            $_.Exception.Message

        $status.Text = 'Não foi possível concluir o diagnóstico.'
        Write-DiagnosticLog ('Falha na coleta. ' + $_.Exception.Message)
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

    try {
        $dataPasta = $script:Resultado.Data.ToString('dd-MM-yyyy')
        $pastaDia = Join-Path $script:PastaBase $dataPasta

        $nomeSeguro = $script:Resultado.Hostname -replace (
            '[^A-Za-z0-9._-]'
        ), '_'

        if ([string]::IsNullOrWhiteSpace($nomeSeguro)) {
            throw 'Hostname inválido para nome de arquivo.'
        }

        $arquivo = Join-Path $pastaDia ($nomeSeguro + '.txt')

        if ($script:ModoDryRun) {
            $status.Text = 'DryRun, relatório não gravado.'

            [void][System.Windows.Forms.MessageBox]::Show(
                $form,
                'O relatório seria salvo em ' + $arquivo,
                'Simulação',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )

            return
        }

        [void][System.IO.Directory]::CreateDirectory($pastaDia)

        if ([System.IO.File]::Exists($arquivo)) {
            $status.Text = 'O relatório deste computador já existe.'

            [void][System.Windows.Forms.MessageBox]::Show(
                $form,
                'O arquivo já existe e foi preservado.' +
                    [Environment]::NewLine + $arquivo,
                'Relatório existente',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )

            return
        }

        $conteudo = Format-NetworkDiagnostic $script:Resultado
        $utf8 = New-Object System.Text.UTF8Encoding($true)

        $bytes = $utf8.GetPreamble() + $utf8.GetBytes(
            $conteudo + [Environment]::NewLine
        )

        # CreateNew impede sobrescrita mesmo em gravações simultâneas.
        $stream = [System.IO.File]::Open(
            $arquivo,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )

        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Dispose()
        $stream = $null

        $status.Text = 'Relatório salvo com sucesso.'
        Write-DiagnosticLog ('Relatório salvo. ' + $arquivo)

        [void][System.Windows.Forms.MessageBox]::Show(
            $form,
            'Relatório salvo em ' + $arquivo,
            'Gravação concluída',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    }
    catch {
        $status.Text = 'Não foi possível salvar o relatório.'
        Write-DiagnosticLog ('Falha na gravação. ' + $_.Exception.Message)

        [void][System.Windows.Forms.MessageBox]::Show(
            $form,
            $_.Exception.Message,
            'Falha na gravação',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
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
