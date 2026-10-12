<#
Proprietário, nome: Erik Pereira Ghijs
Contato: eghijs@gmail.com

Organização, projeto: Diagnostico-Rede
Finalidade do script: Identificar o responsável pela execução,
coletar hostname e MAC dos adaptadores físicos e salvar relatórios
na Área de Trabalho, organizados por data, sem sobrescrever arquivos.

Ambiente previsto: Windows 10 e Windows 11, Windows PowerShell 5.1.
Classificação: Uso interno, confidencial
Controle de versão: Versão 1.0.0, data 12-10-2026
Revisão: 03.

Aviso legal: Script de propriedade exclusiva do autor.
Uso restrito ao ambiente interno autorizado.
Proibida cópia, redistribuição, modificação ou uso sem autorização formal.
Uso indevido sujeito a sanções legais.

Checklist de segurança: Validação de identidade, nome e caminhos.
Logs locais. Modo DryRun disponível.
Não exige privilégios elevados.
Não altera configurações de rede ou políticas de execução.
Em sessão elevada, registra a identidade que executou o processo.
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
$script:Versao = '1.0.0, revisão 03'

$identidade = [System.Security.Principal.WindowsIdentity]::GetCurrent()

try {
    $script:Login = $identidade.Name
    $script:Sid = $identidade.User.Value

    $principal = New-Object System.Security.Principal.WindowsPrincipal(
        $identidade
    )

    $script:Elevado = $principal.IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator
    )
}
finally {
    $identidade.Dispose()
}

# Respeita o redirecionamento da Área de Trabalho, inclusive OneDrive.
$areaTrabalho = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::DesktopDirectory
)

if ([string]::IsNullOrWhiteSpace($areaTrabalho)) {
    throw 'Não foi possível localizar a Área de Trabalho do usuário.'
}

$script:PastaBase = Join-Path $areaTrabalho 'Diagnostico-Rede'

function Get-FullName {
    # Consulta somente contas locais usando o SID da execução.
    # Se o nome não estiver disponível, o operador deverá preenchê-lo.
    try {
        $conta = Get-CimInstance `
            -ClassName Win32_UserAccount `
            -Filter "LocalAccount = TRUE AND SID = '$script:Sid'" `
            -ErrorAction Stop |
            Select-Object -First 1

        if (
            $null -ne $conta -and
            -not [string]::IsNullOrWhiteSpace([string]$conta.FullName)
        ) {
            return ([string]$conta.FullName).Trim()
        }
    }
    catch {
        # A ausência do nome não impede a identificação pelo login.
    }

    return ''
}

function Write-DiagnosticLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mensagem
    )

    if ($script:Simulacao) {
        return
    }

    try {
        $pastaLogs = Join-Path $script:PastaBase 'Logs'
        [void][System.IO.Directory]::CreateDirectory($pastaLogs)

        $arquivoLog = Join-Path $pastaLogs (
            (Get-Date -Format 'dd-MM-yyyy') + '.log'
        )

        $mensagemLimpa = $Mensagem -replace '[\r\n]', ' '

        $linha = '{0}  Login, {1}. {2}{3}' -f (
            Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        ), $script:Login, $mensagemLimpa, [Environment]::NewLine

        $utf8 = New-Object System.Text.UTF8Encoding($true)

        [System.IO.File]::AppendAllText(
            $arquivoLog,
            $linha,
            $utf8
        )
    }
    catch {
        # Falha de log não interrompe o diagnóstico.
        [System.Diagnostics.Debug]::WriteLine($_.Exception.Message)
    }
}

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
    # Inclui adaptadores físicos conectados ou desconectados.
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

            $macs = @(
                foreach ($endereco in @($adaptador.NetworkAddresses)) {
                    $normalizado = ConvertTo-Mac (
                        [string]$endereco
                    )

                    if (
                        -not [string]::IsNullOrWhiteSpace($normalizado)
                    ) {
                        $normalizado
                    }
                }
            )

            $macAtual = if ($macs.Count -gt 0) {
                ($macs | Select-Object -Unique) -join ', '
            }
            else {
                'Não disponível'
            }

            $macPermanente = ConvertTo-Mac (
                [string]$adaptador.PermanentAddress
            )

            if ([string]::IsNullOrWhiteSpace($macPermanente)) {
                $macPermanente = 'Não informado pelo driver'
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
        Hostname   = [Environment]::MachineName
        Login      = $script:Login
        Sid        = $script:Sid
        Elevado    = $script:Elevado
        Data       = Get-Date
        Interfaces = @($interfaces | Sort-Object Tipo, Indice)
    }
}

function Format-NetworkDiagnostic {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Resultado,

        [AllowEmptyString()]
        [string]$NomeCompleto
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

    $nomeRelatorio = if (
        [string]::IsNullOrWhiteSpace($NomeCompleto)
    ) {
        'Preencher antes de salvar'
    }
    else {
        ($NomeCompleto -replace '\s+', ' ').Trim()
    }

    $elevacao = if ($Resultado.Elevado) {
        'Sim'
    }
    else {
        'Não'
    }

    $linhas = New-Object 'System.Collections.Generic.List[string]'

    $linhas.Add('DIAGNÓSTICO DE REDE')
    $linhas.Add('Versão ' + $script:Versao)
    $linhas.Add('')
    $linhas.Add('Nome completo informado: ' + $nomeRelatorio)
    $linhas.Add('Login da execução: ' + $Resultado.Login)
    $linhas.Add('SID da conta: ' + $Resultado.Sid)
    $linhas.Add('Execução elevada: ' + $elevacao)
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
        'O login identifica a conta que executou este processo.'
    )

    $linhas.Add(
        'O nome completo é informado ou confirmado pelo operador.'
    )

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
$form.Text = 'Diagnóstico de Rede, versão ' + $script:Versao
$form.ClientSize = New-Object System.Drawing.Size(820, 690)
$form.MinimumSize = New-Object System.Drawing.Size(750, 600)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$lblNome = New-Object System.Windows.Forms.Label
$lblNome.Text = 'Nome completo'
$lblNome.Location = New-Object System.Drawing.Point(20, 15)
$lblNome.Size = New-Object System.Drawing.Size(150, 25)
$form.Controls.Add($lblNome)

$campoNome = New-Object System.Windows.Forms.TextBox
$campoNome.Location = New-Object System.Drawing.Point(175, 12)
$campoNome.Size = New-Object System.Drawing.Size(625, 28)
$campoNome.Anchor = 'Top, Left, Right'
$campoNome.MaxLength = 150
$campoNome.Text = Get-FullName
$form.Controls.Add($campoNome)

$lblLogin = New-Object System.Windows.Forms.Label
$lblLogin.Text = 'Login da execução, ' + $script:Login
$lblLogin.Location = New-Object System.Drawing.Point(20, 50)
$lblLogin.Size = New-Object System.Drawing.Size(780, 25)
$lblLogin.Anchor = 'Top, Left, Right'
$form.Controls.Add($lblLogin)

$lblModo = New-Object System.Windows.Forms.Label
$lblModo.Location = New-Object System.Drawing.Point(20, 80)
$lblModo.Size = New-Object System.Drawing.Size(780, 25)
$lblModo.Anchor = 'Top, Left, Right'

$lblModo.Text = if ($script:Elevado) {
    'Sessão elevada. O login registrado é a conta desta execução.'
}
else {
    'Execução com usuário comum, sem necessidade de administrador.'
}

$form.Controls.Add($lblModo)

$lblDestino = New-Object System.Windows.Forms.Label
$lblDestino.Text = 'Destino, Área de Trabalho, pasta Diagnostico-Rede.'
$lblDestino.Location = New-Object System.Drawing.Point(20, 110)
$lblDestino.Size = New-Object System.Drawing.Size(780, 25)
$lblDestino.Anchor = 'Top, Left, Right'
$form.Controls.Add($lblDestino)

$texto = New-Object System.Windows.Forms.TextBox
$texto.Location = New-Object System.Drawing.Point(20, 145)
$texto.Size = New-Object System.Drawing.Size(780, 435)
$texto.Multiline = $true
$texto.ReadOnly = $true
$texto.ScrollBars = 'Both'
$texto.WordWrap = $false
$texto.Anchor = 'Top, Bottom, Left, Right'
$texto.Font = New-Object System.Drawing.Font('Consolas', 10)
$texto.Text = 'Informe ou confirme o nome completo e clique em Coletar.'
$form.Controls.Add($texto)

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(20, 590)
$status.Size = New-Object System.Drawing.Size(780, 35)
$status.Anchor = 'Bottom, Left, Right'

$status.Text = if ($script:Simulacao) {
    'Modo DryRun, nenhuma gravação será realizada.'
}
else {
    'Pronto para coletar.'
}

$form.Controls.Add($status)

$btnColetar = New-Object System.Windows.Forms.Button
$btnColetar.Text = 'Coletar'
$btnColetar.Location = New-Object System.Drawing.Point(20, 640)
$btnColetar.Size = New-Object System.Drawing.Size(130, 32)
$btnColetar.Anchor = 'Bottom, Left'
$form.Controls.Add($btnColetar)

$btnSalvar = New-Object System.Windows.Forms.Button
$btnSalvar.Text = 'Salvar relatório'
$btnSalvar.Location = New-Object System.Drawing.Point(165, 640)
$btnSalvar.Size = New-Object System.Drawing.Size(160, 32)
$btnSalvar.Anchor = 'Bottom, Left'
$btnSalvar.Enabled = $false
$form.Controls.Add($btnSalvar)

$btnFechar = New-Object System.Windows.Forms.Button
$btnFechar.Text = 'Fechar'
$btnFechar.Location = New-Object System.Drawing.Point(670, 640)
$btnFechar.Size = New-Object System.Drawing.Size(130, 32)
$btnFechar.Anchor = 'Bottom, Right'
$form.Controls.Add($btnFechar)

$campoNome.Add_TextChanged({
    if ($null -ne $script:Resultado) {
        $texto.Text = Format-NetworkDiagnostic `
            -Resultado $script:Resultado `
            -NomeCompleto $campoNome.Text
    }
})

$btnColetar.Add_Click({
    $btnColetar.Enabled = $false
    $btnSalvar.Enabled = $false
    $script:Resultado = $null
    $form.UseWaitCursor = $true
    $status.Text = 'Consultando os adaptadores de rede.'
    $form.Refresh()

    try {
        $script:Resultado = Get-NetworkDiagnostic

        $texto.Text = Format-NetworkDiagnostic `
            -Resultado $script:Resultado `
            -NomeCompleto $campoNome.Text

        $status.Text = (
            'Coleta concluída. Adaptadores físicos encontrados, {0}.' -f
            $script:Resultado.Interfaces.Count
        )

        $btnSalvar.Enabled = $true

        Write-DiagnosticLog (
            'Coleta concluída. Hostname, ' +
            $script:Resultado.Hostname
        )
    }
    catch {
        $mensagemErro = $_.Exception.Message

        $texto.Text = 'Falha na coleta.' +
            [Environment]::NewLine + $mensagemErro

        $status.Text = 'Não foi possível concluir o diagnóstico.'

        Write-DiagnosticLog (
            'Falha na coleta. ' + $mensagemErro
        )
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

    $nome = ($campoNome.Text -replace '\s+', ' ').Trim()

    if (
        $nome.Length -lt 3 -or
        ($nome -split ' ').Count -lt 2
    ) {
        [void][System.Windows.Forms.MessageBox]::Show(
            $form,
            'Informe o nome completo, incluindo nome e sobrenome.',
            'Identificação do responsável'
        )

        [void]$campoNome.Focus()
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

        $arquivo = Join-Path $pastaDia (
            $nomeSeguro + '.txt'
        )

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
            $status.Text = 'O relatório deste computador já existe.'

            [void][System.Windows.Forms.MessageBox]::Show(
                $form,
                'O arquivo já existe e foi preservado.' +
                    [Environment]::NewLine + $arquivo,
                'Relatório existente'
            )

            return
        }

        $conteudo = Format-NetworkDiagnostic `
            -Resultado $script:Resultado `
            -NomeCompleto $nome

        $utf8 = New-Object System.Text.UTF8Encoding($true)

        $bytes = $utf8.GetPreamble() + $utf8.GetBytes(
            $conteudo + [Environment]::NewLine
        )

        # CreateNew impede sobrescrita, inclusive em execução simultânea.
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

        Write-DiagnosticLog (
            'Relatório salvo. Responsável, ' +
            $nome + '. Arquivo, ' + $arquivo
        )

        [void][System.Windows.Forms.MessageBox]::Show(
            $form,
            'Relatório salvo em ' + $arquivo,
            'Gravação concluída'
        )
    }
    catch {
        $mensagemErro = $_.Exception.Message

        if ($null -ne $stream) {
            $stream.Dispose()
            $stream = $null
        }

        # Remove somente o arquivo incompleto criado nesta tentativa.
        if ($arquivoCriado -and $null -ne $arquivo) {
            try {
                [System.IO.File]::Delete($arquivo)
            }
            catch {
                Write-DiagnosticLog (
                    'Não foi possível remover o arquivo incompleto.'
                )
            }
        }

        $status.Text = 'Não foi possível salvar o relatório.'

        Write-DiagnosticLog (
            'Falha na gravação. ' + $mensagemErro
        )

        [void][System.Windows.Forms.MessageBox]::Show(
            $form,
            $mensagemErro,
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
