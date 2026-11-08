<#
Proprietário, nome: Erik Pereira Ghijs
Contato: eghijs@gmail.com

Organização, projeto: NexusCloud Toolbox
Finalidade do script: Validar ferramentas cadastradas e executá-las
com a permissão definida no catálogo.
Ambiente previsto: Windows 10 e 11, Windows PowerShell 5.1.
Classificação: Uso interno, confidencial
Controle de versão: Versão 0.2.4, data 08-11-2026

Aviso legal: Script de propriedade exclusiva do autor.
Uso restrito ao ambiente interno autorizado.
Proibida cópia, redistribuição, modificação ou uso sem autorização formal.
Uso indevido sujeito a sanções legais.

Checklist de segurança: SHA-256 obrigatório.
Catálogo importado como dados e nomes de arquivo restritos.
A central permanece como usuário comum.
Elevação solicitada pelo UAC somente quando cadastrada.
Sem alteração de política de execução pelo executor.
DryRun encaminhado somente a ferramentas compatíveis.
Logs por execução.
Os arquivos locais precisam vir de fonte confiável.
Hashes em catálogo editável não substituem assinatura digital
nem permissões de gravação restritas.
#>

#Requires -Version 5.1

Set-StrictMode -Version Latest

function Assert-ArquivoRegular {
    param(
        [Parameter(Mandatory)]
        [string]$Caminho
    )

    $item = Get-Item -LiteralPath $Caminho -Force -ErrorAction Stop

    if (
        $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    ) {
        throw 'É necessário um arquivo regular, sem links.'
    }
}

function Get-FerramentasAutorizadas {
    [CmdletBinding()]
    param()

    $arquivo = Join-Path $PSScriptRoot 'Catalogo.psd1'
    Assert-ArquivoRegular $arquivo

    $catalogo = Import-PowerShellDataFile `
        -LiteralPath $arquivo -ErrorAction Stop

    if (-not $catalogo.ContainsKey('Ferramentas')) {
        throw 'Catálogo sem ferramentas.'
    }

    $ids = @{}

    foreach ($item in @($catalogo.Ferramentas)) {
        if ($item -isnot [hashtable]) {
            throw 'Entrada inválida no catálogo.'
        }

        foreach ($campo in @(
            'Id', 'Nome', 'Categoria', 'Descricao', 'Versao',
            'Arquivo', 'SHA256', 'ExigeAdministrador',
            'PermiteSimulacao', 'ParametrosPermitidos'
        )) {
            if (-not $item.ContainsKey($campo)) {
                throw "Campo ausente, $campo."
            }
        }

        if ([string]$item.Id -cnotmatch '^[a-z0-9-]+$') {
            throw 'Identificador inválido.'
        }

        if ($ids.ContainsKey($item.Id)) {
            throw 'Identificador duplicado.'
        }

        $ids[$item.Id] = $true

        if (
            [string]$item.Arquivo -notmatch
            '^[A-Za-z0-9][A-Za-z0-9._-]*\.ps1$'
        ) {
            throw 'Nome de arquivo inválido.'
        }

        if (
            $item.ExigeAdministrador -isnot [bool] -or
            $item.PermiteSimulacao -isnot [bool]
        ) {
            throw 'Permissões inválidas no catálogo.'
        }

        foreach ($parametro in @($item.ParametrosPermitidos)) {
            if ($parametro -cne 'DryRun') {
                throw 'Parâmetro não autorizado nesta versão.'
            }
        }

        [pscustomobject]$item
    }
}

function Get-HashBytes {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    $sha = [Security.Cryptography.SHA256]::Create()

    try {
        (
            [BitConverter]::ToString(
                $sha.ComputeHash($Bytes)
            )
        ).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
}

function Start-FerramentaAutorizada {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [switch]$DryRun
    )

    if ($env:OS -ne 'Windows_NT') {
        throw 'Este executor requer Windows.'
    }

    $identidade = [Security.Principal.WindowsIdentity]::GetCurrent()

    try {
        $principal = New-Object Security.Principal.WindowsPrincipal(
            $identidade
        )

        if (
            $principal.IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator
            )
        ) {
            throw 'Abra a central como usuário comum.'
        }
    }
    finally {
        $identidade.Dispose()
    }

    $itens = @(
        Get-FerramentasAutorizadas |
        Where-Object { $_.Id -ceq $Id }
    )

    if ($itens.Count -ne 1) {
        throw 'Ferramenta não autorizada.'
    }

    $ferramenta = $itens[0]

    if (
        $DryRun -and
        (
            -not $ferramenta.PermiteSimulacao -or
            'DryRun' -cnotin @($ferramenta.ParametrosPermitidos)
        )
    ) {
        throw 'A ferramenta não permite simulação.'
    }

    $esperado = (
        [string]$ferramenta.SHA256
    ).Trim().ToUpperInvariant()

    if ($esperado -notmatch '^[A-F0-9]{64}$') {
        throw 'SHA-256 aprovado ausente ou inválido.'
    }

    $origem = Join-Path $PSScriptRoot $ferramenta.Arquivo
    Assert-ArquivoRegular $origem

    $bytes = [IO.File]::ReadAllBytes($origem)
    $recebido = Get-HashBytes -Bytes $bytes

    if ($recebido -cne $esperado) {
        throw 'Integridade inválida. Execução bloqueada.'
    }

    $utf8Estrito = New-Object Text.UTF8Encoding($false, $true)

    try {
        $codigo = $utf8Estrito.GetString($bytes).TrimStart(
            [char]0xFEFF
        )
    }
    catch {
        throw 'O arquivo aprovado precisa estar codificado em UTF-8.'
    }

    $tokens = $null
    $errosSintaxe = $null

    [void][Management.Automation.Language.Parser]::ParseInput(
        $codigo,
        [ref]$tokens,
        [ref]$errosSintaxe
    )

    if (@($errosSintaxe).Count -gt 0) {
        throw 'A ferramenta contém erros de sintaxe.'
    }

    $local = [Environment]::GetFolderPath('LocalApplicationData')

    if ([string]::IsNullOrWhiteSpace($local)) {
        throw 'Pasta local do usuário indisponível.'
    }

    $pasta = Join-Path (
        Join-Path $local 'NexusCloud-Toolbox\Execucoes'
    ) ([guid]::NewGuid().ToString('N'))

    [void][IO.Directory]::CreateDirectory($pasta)

    $copia = Join-Path $pasta $ferramenta.Arquivo
    $utf8ComBom = New-Object Text.UTF8Encoding($true)

    # Normaliza somente a codificação da cópia de execução.
    # O arquivo original permanece intacto.
    $bytesExecucao = $utf8ComBom.GetPreamble() +
        $utf8ComBom.GetBytes($codigo)

    [IO.File]::WriteAllBytes($copia, $bytesExecucao)

    $hashExecucao = Get-HashBytes -Bytes $bytesExecucao

    $hashGravado = (
        Get-FileHash -LiteralPath $copia `
            -Algorithm SHA256 -ErrorAction Stop
    ).Hash

    if ($hashGravado -cne $hashExecucao) {
        throw 'Falha ao validar a cópia de execução.'
    }

    $powershell = Join-Path $env:SystemRoot (
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    )

    if (-not [IO.File]::Exists($powershell)) {
        throw 'Windows PowerShell não localizado.'
    }

    $argumentos = '-NoLogo -NoProfile -STA -File "' + $copia + '"'

    if ($DryRun) {
        $argumentos += ' -DryRun'
    }

    $registro = Join-Path $pasta 'Execucao.json'

    $dados = [ordered]@{
        Ferramenta          = $ferramenta.Id
        Versao              = $ferramenta.Versao
        SHA256              = $esperado
        SHA256Copia         = $hashExecucao
        Simulacao           = [bool]$DryRun
        ExigeAdministrador  = $ferramenta.ExigeAdministrador
        Inicio              = (Get-Date).ToString('o')
        Estado              = 'Preparada'
        Processo            = $null
    }

    [IO.File]::WriteAllText(
        $registro,
        ($dados | ConvertTo-Json),
        $utf8ComBom
    )

    $processo = $null

    try {
        if ($ferramenta.ExigeAdministrador) {
            # UAC solicita consentimento ou credenciais administrativas.
            # A ferramenta de hotspot não possui interface própria.
            $processo = Start-Process `
                -FilePath $powershell `
                -ArgumentList $argumentos `
                -WorkingDirectory $pasta `
                -Verb RunAs `
                -WindowStyle Hidden `
                -PassThru `
                -ErrorAction Stop
        }
        else {
            # Ferramentas gráficas comuns sem console adicional.
            $inicio = New-Object Diagnostics.ProcessStartInfo
            $inicio.FileName = $powershell
            $inicio.Arguments = $argumentos
            $inicio.WorkingDirectory = $pasta
            $inicio.UseShellExecute = $false
            $inicio.CreateNoWindow = $true

            $processo = New-Object Diagnostics.Process
            $processo.StartInfo = $inicio

            if (-not $processo.Start()) {
                throw 'Não foi possível iniciar a ferramenta.'
            }
        }

        if ($null -eq $processo) {
            throw 'O processo da ferramenta não foi retornado.'
        }
    }
    catch {
        $falha = $_

        if ($null -ne $processo) {
            $processo.Dispose()
        }

        $dados.Estado = 'Falha ou cancelamento ao iniciar'

        try {
            [IO.File]::WriteAllText(
                $registro,
                ($dados | ConvertTo-Json),
                $utf8ComBom
            )
        }
        catch {
            Write-Warning 'Não foi possível registrar a falha.'
        }

        throw (
            'A ferramenta não foi iniciada. ' +
            'A autorização UAC pode ter sido cancelada. ' +
            $falha.Exception.Message
        )
    }

    $dados.Estado = 'Iniciada'
    $dados.Processo = $processo.Id

    try {
        [IO.File]::WriteAllText(
            $registro,
            ($dados | ConvertTo-Json),
            $utf8ComBom
        )
    }
    catch {
        Write-Warning 'Não foi possível atualizar o registro.'
    }

    [pscustomobject]@{
        Processo = $processo
        Pasta    = $pasta
        Saida    = Join-Path $pasta 'Saida.txt'
        Erros    = Join-Path $pasta 'Erros.txt'
        Registro = $registro
    }
}

Export-ModuleMember -Function @(
    'Get-FerramentasAutorizadas',
    'Start-FerramentaAutorizada'
)