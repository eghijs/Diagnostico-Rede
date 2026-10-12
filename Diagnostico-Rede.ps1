<#
Proprietário, nome: Erik Pereira Ghijs
Contato: eghijs@gmail.com

Organização, projeto: Diagnostico-Rede
Finalidade do script: Identificar automaticamente a conta da execução,
coletar hostname e MAC dos adaptadores físicos e salvar relatório
na Área de Trabalho, organizado por data, sem sobrescrever arquivos.

Ambiente previsto: Windows 10 e Windows 11, Windows PowerShell 5.1.
Classificação: Uso interno, confidencial
Controle de versão: Versão 1.0.0, data 12-10-2026
Revisão: 04.

Aviso legal: Script de propriedade exclusiva do autor.
Uso restrito ao ambiente interno autorizado.
Proibida cópia, redistribuição, modificação ou uso sem autorização formal.
Uso indevido sujeito a sanções legais.

Checklist de segurança: Validação da identidade e dos caminhos.
Logs locais. Modo DryRun disponível.
Não exige privilégios elevados.
Não altera contas, configurações de rede ou políticas de execução.
O nome completo depende das informações disponíveis na conta.
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

$script:Versao = '1.0.0, revisão 04'
$script:Resultado = $null
$script:Simulacao = [bool]$DryRun

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

$areaTrabalho = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::DesktopDirectory
)

if ([string]::IsNullOrWhiteSpace($areaTrabalho)) {
    throw 'Não foi possível localizar a Área de Trabalho.'
}

$script:PastaBase = Join-Path $areaTrabalho 'Diagnostico-Rede'

function Get-AutomaticIdentity {
    $nome = ''
    $origem = 'Não disponível'

    # Primeira tentativa, cadastro da conta local correspondente ao SID.
    try {
        $conta = Get-CimInstance `
            -ClassName Win32_UserAccount `
            -Filter "LocalAccount = TRUE AND SID = '$script:Sid'" `
            -OperationTimeoutSec 10 `
            -ErrorAction Stop |
            Select-Object -First 1

        if ($null -ne $conta) {
            $nome = ([string]$conta.FullName).Trim()

            if (-not [string]::IsNullOrWhiteSpace($nome)) {
                $origem = 'Cadastro da conta local'
            }
        }
    }
    catch {
        # Continua com as outras formas de consulta.
    }

    # Segunda tentativa, módulo de contas locais, quando disponível.
    if ([string]::IsNullOrWhiteSpace($nome)) {
        try {
            if (
                $null -ne (
                    Get-Command Get-LocalUser -ErrorAction SilentlyContinue
                )
            ) {
                $sidObjeto = New-Object `
                    System.Security.Principal.SecurityIdentifier(
                        $script:Sid
                    )

                $contaLocal = Get-LocalUser `
                    -SID $sidObjeto `
                    -ErrorAction Stop

                $nome = ([string]$contaLocal.FullName).Trim()

                if (-not [string]::IsNullOrWhiteSpace($nome)) {
                    $origem = 'Cadastro de usuário local'
                }
            }
        }
        catch {
            # Conta de domínio ou nome local não disponível.
        }
    }

    # Terceira tentativa, nome de exibição da identidade do Windows.
    if ([string]::IsNullOrWhiteSpace($nome)) {
        try {
            if (
                $null -eq (
                    'DiagnosticoRede.NativeIdentity' -as [type]
                )
            ) {
                Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace DiagnosticoRede
{
    public static class NativeIdentity
    {
        [DllImport(
            "secur32.dll",
            EntryPoint = "GetUserNameExW",
            CharSet = CharSet.Unicode,
            SetLastError = true)]
        [return: MarshalAs(UnmanagedType.U1)]
        private static extern bool GetUserNameEx(
            int nameFormat,
            StringBuilder userName,
            ref uint size);

        public static string GetDisplayName()
        {
            uint size = 512;
            StringBuilder buffer = new StringBuilder((int)size);

            if (GetUserNameEx(3, buffer, ref size))
                return buffer.ToString();

            int error = Marshal.GetLastWin32Error();

            if (error == 234 && size > 0 && size <= 32768)
            {
                buffer = new StringBuilder((int)size);

                if (GetUserNameEx(3, buffer, ref size))
                    return buffer.ToString();
            }

            return String.Empty;
        }
    }
}
'@
            }

            $nome = (
                [DiagnosticoRede.NativeIdentity]::GetDisplayName()
            ).Trim()

            if (-not [string]::IsNullOrWhiteSpace($nome)) {
                $origem = 'Nome de exibição do Windows'
            }
        }
        catch {
            # Não solicita nome, senha ou elevação.
        }
    }

    if ([string]::IsNullOrWhiteSpace($nome)) {
        $nome = 'Nome completo não disponível'
    }

    [pscustomobject]@{
        NomeCompleto = ($nome -replace '\s+', ' ').Trim()
        OrigemNome   = $origem
        Login        = $script:Login
        Sid          = $script:Sid
        Elevado      = $script:Elevado
    }
}

function Write-DiagnosticLog {
    param([string]$Mensagem)

    if ($script:Simulacao) {
        return
    }

    try {
        $pasta = Join-Path $script:PastaBase 'Logs'
        [void][System.IO.Directory]::CreateDirectory($pasta)

        $arquivo = Join-Path $pasta (
            (Get-Date -Format 'dd-MM-yyyy') + '.log'
        )

        $linha = '{0}  Login, {1}. {2}{3}' -f (
            Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        ), $script:Login, (
            $Mensagem -replace '[\r\n]', ' '
        ), [Environment]::NewLine

        $utf8 = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::AppendAllText($arquivo, $linha, $utf8)
    }
    catch {
        [System.Diagnostics.Debug]::WriteLine($_.Exception.Message)
    }
}

function ConvertTo-Mac {
    param([AllowNull()][string]$Endereco)

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
    $responsavel = Get-AutomaticIdentity

    $adaptadores = @(
        Get-CimInstance `
            -Namespace 'root/StandardCimv2' `
            -ClassName 'MSFT_NetAdapter' `
            -OperationTimeoutSec 15 `
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
                    $mac = ConvertTo-Mac ([string]$endereco)

                    if (-not [string]::IsNullOrWhiteSpace($mac)) {
                        $mac
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
        Responsavel = $responsavel
        Data       = Get-Date
        Interfaces = @($interfaces | Sort-Object Tipo, Indice)
    }
}

function Format-NetworkDiagnostic {
    param([psobject]$Resultado)

    $linhas = New-Object 'System.Collections.Generic.List[string]'
    $responsavel = $Resultado.Responsavel

    $linhas.Add('DIAGNÓSTICO DE REDE')
    $linhas.Add('Versão ' + $script:Versao)
    $linhas.Add('')
    $linhas.Add('Nome completo: ' + $responsavel.NomeCompleto)
    $linhas.Add('Origem do nome: ' + $responsavel.OrigemNome)
    $linhas.Add('Login da execução: ' + $responsavel.Login)
    $linhas.Add('SID da conta: ' + $responsavel.Sid)

    $elevacao = if ($responsavel.Elevado) { 'Sim' } else { 'Não' }
    $linhas.Add('Execução elevada: ' + $elevacao)
    $linhas.Add('')
    $linhas.Add('Hostname: ' + $Resultado.Hostname)

    foreach ($tipo in @('Wi-Fi', 'Cabo')) {
        $selecionados = @(
            $Resultado.Interfaces |
            Where-Object { $_.Tipo -eq $tipo }
        )

        $resumo = if ($selecionados.Count -gt 0) {
            ($selecionados | ForEach-Object { $_.MacAtual }) -join ', '
        }
        else {
            'Nenhum adaptador identificado'
        }

        $linhas.Add('Mac ' + $tipo + ': ' + $resumo)
    }

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
        'A identidade corresponde à conta que executou o processo.'
    )
    $linhas.Add(
        'O nome é consultado automaticamente, sem preenchimento manual.'
    )
    $linhas.Add(
        'O nome disponível no cadastro pode estar incompleto.'
    )
    $linhas.Add(
        'O MAC atual pode diferir do permanente por randomização ' +
        'do Wi-Fi ou configuração do adaptador.'
    )
    $linhas.Add(
        'A classificação e o MAC permanente dependem do driver.'
    )

    return $linhas -join [Environment]::NewLine
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Diagnóstico de Rede, versão ' + $script:Versao
$form.ClientSize = New-Object System.Drawing.Size(820, 650)
$form.MinimumSize = New-Object System.Drawing.Size(750, 550)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$info = New-Object System.Windows.Forms.Label
$info.Location = New-Object System.Drawing.Point(20, 15)
$info.Size = New-Object System.Drawing.Size(780, 65)
$info.Anchor = 'Top, Left, Right'
$info.Text = (
    'Identificação automática. Login, ' + $script:Login +
    [Environment]::NewLine +
    'Destino, Área de Trabalho, pasta Diagnostico-Rede.'
)
$form.Controls.Add($info)

$texto = New-Object System.Windows.Forms.TextBox
$texto.Location = New-Object System.Drawing.Point(20, 90)
$texto.Size = New-Object System.Drawing.Size(780, 450)
$texto.Multiline = $true
$texto.ReadOnly = $true
$texto.ScrollBars = 'Both'
$texto.WordWrap = $false
$texto.Anchor = 'Top, Bottom, Left, Right'
$texto.Font = New-Object System.Drawing.Font('Consolas', 10)
$texto.Text = 'Clique em Coletar. Não é necessário digitar o nome.'
$form.Controls.Add($texto)

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(20, 550)
$status.Size = New-Object System.Drawing.Size(780, 35)
$status.Anchor = 'Bottom, Left, Right'
$status.Text = if ($script:Simulacao) {
    'Modo DryRun, nenhuma gravação será realizada.'
}
elseif ($script:Elevado) {
    'Sessão elevada. Será registrada a conta desta execução.'
}
else {
    'Pronto. Execução sem privilégios administrativos.'
}
$form.Controls.Add($status)

$btnColetar = New-Object System.Windows.Forms.Button
$btnColetar.Text = 'Coletar'
$btnColetar.Location = New-Object System.Drawing.Point(20, 600)
$btnColetar.Size = New-Object System.Drawing.Size(130, 32)
$btnColetar.Anchor = 'Bottom, Left'
$form.Controls.Add($btnColetar)

$btnSalvar = New-Object System.Windows.Forms.Button
$btnSalvar.Text = 'Salvar relatório'
$btnSalvar.Location = New-Object System.Drawing.Point(165, 600)
$btnSalvar.Size = New-Object System.Drawing.Size(160, 32)
$btnSalvar.Anchor = 'Bottom, Left'
$btnSalvar.Enabled = $false
$form.Controls.Add($btnSalvar)

$btnFechar = New-Object System.Windows.Forms.Button
$btnFechar.Text = 'Fechar'
$btnFechar.Location = New-Object System.Drawing.Point(670, 600)
$btnFechar.Size = New-Object System.Drawing.Size(130, 32)
$btnFechar.Anchor = 'Bottom, Right'
$form.Controls.Add($btnFechar)

$btnColetar.Add_Click({
    $btnColetar.Enabled = $false
    $btnSalvar.Enabled = $false
    $script:Resultado = $null
    $form.UseWaitCursor = $true
    $status.Text = 'Identificando a conta e consultando a rede.'
    $form.Refresh()

    try {
        $script:Resultado = Get-NetworkDiagnostic
        $texto.Text = Format-NetworkDiagnostic $script:Resultado

        $status.Text = if (
            $script:Resultado.Responsavel.OrigemNome -eq 'Não disponível'
        ) {
            'Coleta concluída. Nome indisponível, login identificado.'
        }
        else {
            'Coleta concluída. Nome e login identificados automaticamente.'
        }

        $btnSalvar.Enabled = $true
        Write-DiagnosticLog (
            'Coleta concluída. Hostname, ' + $script:Resultado.Hostname
        )
    }
    catch {
        $erroColeta = $_.Exception.Message
        $texto.Text = 'Falha na coleta.' +
            [Environment]::NewLine + $erroColeta
        $status.Text = 'Não foi possível concluir o diagnóstico.'
        Write-DiagnosticLog ('Falha na coleta. ' + $erroColeta)
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
            $status.Text = 'O relatório já existe e foi preservado.'
            [void][System.Windows.Forms.MessageBox]::Show(
                $form,
                'O arquivo já existe e foi preservado.' +
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
        Write-DiagnosticLog ('Relatório salvo. ' + $arquivo)

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
                Write-DiagnosticLog (
                    'Não foi possível remover o arquivo incompleto.'
                )
            }
        }

        $status.Text = 'Não foi possível salvar o relatório.'
        Write-DiagnosticLog ('Falha na gravação. ' + $erroGravacao)

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
