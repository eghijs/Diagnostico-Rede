<#
Proprietário, nome: Erik Pereira Ghijs
Contato: eghijs@gmail.com

Organização, projeto: NexusCloud Toolbox
Finalidade do script: Selecionar ferramentas por checkbox e coordenar
sua execução em processos separados, usando o executor autorizado.
Ambiente previsto: Windows 10 e 11, Windows PowerShell 5.1, modo STA.
Classificação: Uso interno, confidencial
Controle de versão: Versão 0.2.1, data 08-11-2026

Aviso legal: Script de propriedade exclusiva do autor.
Uso restrito ao ambiente interno autorizado.
Proibida cópia, redistribuição, modificação ou uso sem autorização formal.
Uso indevido sujeito a sanções legais.

Checklist de segurança: Sem comandos livres.
Catálogo e SHA-256 validados pelo Executor.psm1.
Execução administrativa bloqueada.
Logs por execução e histórico visual.
Simulação encaminhada somente a ferramentas compatíveis.
Não modifica políticas de execução.
Não baixa código remoto.
#>

#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'Esta central requer Windows.'
}

if (
    [Threading.Thread]::CurrentThread.ApartmentState -ne
    [Threading.ApartmentState]::STA
) {
    throw 'Abra a central no Windows PowerShell em modo STA.'
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

Import-Module (
    Join-Path $PSScriptRoot 'Executor.psm1'
) -Force -ErrorAction Stop

$ferramentas = @(Get-FerramentasAutorizadas)

Add-Type -AssemblyName PresentationFramework

[xml]$xaml = @'
<Window
 xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="NexusCloud Toolbox v0.2.1"
 Width="1050" Height="740"
 MinWidth="850" MinHeight="620"
 WindowStartupLocation="CenterScreen"
 Background="#151B23"
 Foreground="#F0F4F8"
 FontFamily="Segoe UI"
 FontSize="14">

 <Window.Resources>
  <Style TargetType="Button">
   <Setter Property="Padding" Value="18,10"/>
   <Setter Property="Margin" Value="5"/>
   <Setter Property="Background" Value="#263342"/>
   <Setter Property="Foreground" Value="White"/>
   <Setter Property="BorderBrush" Value="#526274"/>
   <Setter Property="Cursor" Value="Hand"/>
  </Style>
 </Window.Resources>

 <Grid Margin="24">
  <Grid.RowDefinitions>
   <RowDefinition Height="Auto"/>
   <RowDefinition Height="Auto"/>
   <RowDefinition Height="*"/>
   <RowDefinition Height="Auto"/>
   <RowDefinition Height="190"/>
   <RowDefinition Height="Auto"/>
  </Grid.RowDefinitions>

  <StackPanel Grid.Row="0" Margin="0,0,0,18">
   <TextBlock Text="NexusCloud Toolbox"
              FontSize="30"
              FontWeight="Bold"
              Foreground="#00C8EE"/>
   <TextBlock Text="Central de ferramentas"
              Foreground="#A9B7C6"
              Margin="0,6,0,0"/>
  </StackPanel>

  <TextBlock Grid.Row="1"
             Text="Marque os serviços que deseja executar."
             Margin="0,0,0,12"/>

  <Border Grid.Row="2"
          Background="#1C2633"
          BorderBrush="#46566A"
          BorderThickness="1"
          Padding="16">
   <ScrollViewer VerticalScrollBarVisibility="Auto">
    <StackPanel x:Name="Servicos"/>
   </ScrollViewer>
  </Border>

  <StackPanel Grid.Row="3" Margin="0,12">
   <TextBlock x:Name="Contagem"
              Text="Nenhum serviço selecionado."
              Foreground="#B6C5D4"
              Margin="5"/>
   <WrapPanel HorizontalAlignment="Right">
    <Button x:Name="Limpar" Content="Limpar seleção"/>
    <Button x:Name="Simular" Content="Simular selecionados"/>
    <Button x:Name="Executar"
            Content="Executar selecionados"
            Background="#007E9E"/>
   </WrapPanel>
   <TextBlock x:Name="Status"
              Text="Pronto."
              TextWrapping="Wrap"
              Margin="5"/>
  </StackPanel>

  <TextBox x:Name="Historico"
           Grid.Row="4"
           Background="#0E141C"
           Foreground="#D8EAF7"
           BorderBrush="#46566A"
           Padding="12"
           FontFamily="Consolas"
           FontSize="12"
           IsReadOnly="True"
           AcceptsReturn="True"
           TextWrapping="Wrap"
           VerticalScrollBarVisibility="Auto"/>

  <TextBlock Grid.Row="5"
             Text="v0.2.1. Execução local como usuário comum."
             Foreground="#A9B7C6"
             Margin="0,12,0,0"/>
 </Grid>
</Window>
'@

$leitor = New-Object Xml.XmlNodeReader($xaml)

try {
    $janela = [Windows.Markup.XamlReader]::Load($leitor)
}
finally {
    $leitor.Close()
}

$ui = @{}

foreach ($nome in @(
    'Servicos', 'Contagem', 'Limpar',
    'Simular', 'Executar', 'Status', 'Historico'
)) {
    $controle = $janela.FindName($nome)

    if ($null -eq $controle) {
        throw "Controle ausente, $nome."
    }

    $ui[$nome] = $controle
}

$script:Checks = New-Object Collections.ArrayList
$script:Fila = New-Object Collections.Queue
$script:Atual = $null
$script:Ocupado = $false
$script:ModoSimulacao = $false
$script:HouveFalha = $false

function Add-Historico {
    param([string]$Mensagem)

    $ui.Historico.AppendText(
        ('[{0}] {1}{2}' -f (
            Get-Date -Format 'HH:mm:ss'
        ), $Mensagem, [Environment]::NewLine)
    )

    $ui.Historico.ScrollToEnd()
}

function Update-Selecao {
    $selecionados = @(
        $script:Checks |
        Where-Object { $_.IsChecked -eq $true }
    )

    $ui.Contagem.Text = (
        'Serviços selecionados, ' + $selecionados.Count + '.'
    )

    $podeExecutar = (
        -not $script:Ocupado -and
        $selecionados.Count -gt 0
    )

    $ui.Executar.IsEnabled = $podeExecutar

    $incompativeis = @(
        $selecionados |
        Where-Object { -not $_.Tag.PermiteSimulacao }
    )

    $ui.Simular.IsEnabled = (
        $podeExecutar -and $incompativeis.Count -eq 0
    )

    $ui.Limpar.IsEnabled = -not $script:Ocupado
    $ui.Servicos.IsEnabled = -not $script:Ocupado
}

function Complete-Fila {
    $script:Ocupado = $false

    if ($script:HouveFalha) {
        $ui.Status.Text = 'Fila finalizada com falhas ou bloqueios.'
    }
    else {
        $ui.Status.Text = 'Fila finalizada. Confira o resultado nas ferramentas.'
    }

    Add-Historico $ui.Status.Text
    Update-Selecao
}

function Start-ProximaFerramenta {
    if ($script:Fila.Count -eq 0) {
        Complete-Fila
        return
    }

    $ferramenta = $script:Fila.Dequeue()

    try {
        $execucao = Start-FerramentaAutorizada `
            -Id $ferramenta.Id `
            -DryRun:$script:ModoSimulacao

        $script:Atual = [pscustomobject]@{
            Nome     = $ferramenta.Nome
            Execucao = $execucao
        }

        $ui.Status.Text = (
            'Em execução, ' + $ferramenta.Nome +
            '. Utilize a janela da ferramenta.'
        )

        Add-Historico (
            'Ferramenta iniciada, ' + $ferramenta.Nome + '.'
        )
    }
    catch {
        $script:HouveFalha = $true
        $script:Fila.Clear()
        Add-Historico ('Execução bloqueada, ' + $_.Exception.Message)
        Complete-Fila
    }
}

function Start-Selecionados {
    param([bool]$Simulacao)

    if ($script:Ocupado) {
        return
    }

    $selecionados = @(
        $script:Checks |
        Where-Object { $_.IsChecked -eq $true }
    )

    if ($selecionados.Count -eq 0) {
        return
    }

    if ($Simulacao) {
        foreach ($checkbox in $selecionados) {
            if (-not $checkbox.Tag.PermiteSimulacao) {
                Add-Historico 'Seleção contém ferramenta sem simulação.'
                return
            }
        }
    }

    $script:Fila.Clear()

    foreach ($checkbox in $selecionados) {
        $script:Fila.Enqueue($checkbox.Tag)
    }

    $script:ModoSimulacao = $Simulacao
    $script:HouveFalha = $false
    $script:Ocupado = $true

    Update-Selecao

    Add-Historico (
        'Fila iniciada. Simulação, ' + $Simulacao + '.'
    )

    Start-ProximaFerramenta
}

foreach ($grupo in @(
    $ferramentas |
    Group-Object Categoria |
    Sort-Object Name
)) {
    $titulo = New-Object Windows.Controls.TextBlock
    $titulo.Text = $grupo.Name
    $titulo.FontSize = 18
    $titulo.FontWeight = [Windows.FontWeights]::Bold
    $titulo.Foreground = [Windows.Media.Brushes]::DeepSkyBlue
    $titulo.Margin = New-Object Windows.Thickness(0, 8, 0, 10)

    [void]$ui.Servicos.Children.Add($titulo)

    foreach ($ferramenta in $grupo.Group) {
        $checkbox = New-Object Windows.Controls.CheckBox
        $checkbox.Content = (
            $ferramenta.Nome + '    v' + $ferramenta.Versao
        )
        $checkbox.Tag = $ferramenta
        $checkbox.Foreground = [Windows.Media.Brushes]::White
        $checkbox.FontSize = 16
        $checkbox.Margin = New-Object Windows.Thickness(0, 8, 0, 4)

        $checkbox.Add_Checked({ Update-Selecao })
        $checkbox.Add_Unchecked({ Update-Selecao })

        [void]$script:Checks.Add($checkbox)
        [void]$ui.Servicos.Children.Add($checkbox)

        $descricao = New-Object Windows.Controls.TextBlock
        $descricao.Text = $ferramenta.Descricao
        $descricao.TextWrapping = [Windows.TextWrapping]::Wrap
        $descricao.Foreground = [Windows.Media.Brushes]::LightGray
        $descricao.Margin = New-Object Windows.Thickness(24, 0, 0, 14)

        [void]$ui.Servicos.Children.Add($descricao)
    }
}

$ui.Limpar.Add_Click({
    foreach ($checkbox in $script:Checks) {
        $checkbox.IsChecked = $false
    }

    Update-Selecao
})

$ui.Executar.Add_Click({
    Start-Selecionados -Simulacao $false
})

$ui.Simular.Add_Click({
    Start-Selecionados -Simulacao $true
})

$temporizador = New-Object Windows.Threading.DispatcherTimer
$temporizador.Interval = [TimeSpan]::FromMilliseconds(500)

$temporizador.Add_Tick({
    if ($null -eq $script:Atual) {
        return
    }

    $atual = $script:Atual
    $execucao = $atual.Execucao

    # Não inicia outra ferramenta se o acompanhamento do processo falhar.
    try {
        $execucao.Processo.Refresh()

        if (-not $execucao.Processo.HasExited) {
            return
        }

        $execucao.Processo.WaitForExit()
        $codigo = $execucao.Processo.ExitCode
    }
    catch {
        $temporizador.Stop()
        $script:Fila.Clear()
        $ui.Status.Text = 'Falha ao acompanhar o processo.'
        Add-Historico (
            'Verifique a ferramenta aberta. ' + $_.Exception.Message
        )
        return
    }

    foreach ($arquivo in @($execucao.Saida, $execucao.Erros)) {
        try {
            if ([IO.File]::Exists($arquivo)) {
                $texto = [IO.File]::ReadAllText(
                    $arquivo,
                    [Text.Encoding]::UTF8
                )

                if (-not [string]::IsNullOrWhiteSpace($texto)) {
                    Add-Historico $texto.Trim()
                }
            }
        }
        catch {
            Add-Historico 'Não foi possível ler uma saída do processo.'
        }
    }

    try {
        $registro = Get-Content `
            -LiteralPath $execucao.Registro `
            -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json

        $registro.Estado = 'Processo encerrado'

        $registro | Add-Member `
            -NotePropertyName 'CodigoSaida' `
            -NotePropertyValue $codigo -Force

        $registro | Add-Member `
            -NotePropertyName 'Fim' `
            -NotePropertyValue (Get-Date).ToString('o') -Force

        [IO.File]::WriteAllText(
            $execucao.Registro,
            ($registro | ConvertTo-Json),
            (New-Object Text.UTF8Encoding($true))
        )
    }
    catch {
        Add-Historico 'Não foi possível atualizar o registro final.'
    }

    Add-Historico (
        'Processo encerrado, ' + $atual.Nome +
        '. Código, ' + $codigo + '.'
    )

    Add-Historico ('Registros da execução, ' + $execucao.Pasta)

    $execucao.Processo.Dispose()
    $script:Atual = $null

    if ($codigo -ne 0) {
        $script:HouveFalha = $true
        $script:Fila.Clear()
    }

    Start-ProximaFerramenta
})

$janela.Add_Closing({
    param($sender, $evento)

    if ($script:Ocupado) {
        $evento.Cancel = $true
        Add-Historico 'Feche a ferramenta em execução antes de sair da central.'
    }
})

Update-Selecao
Add-Historico 'Central iniciada. Marque o serviço desejado.'
Add-Historico 'O diagnóstico mantém seus próprios botões Coletar e Salvar relatório.'

$temporizador.Start()

try {
    [void]$janela.ShowDialog()
}
finally {
    $temporizador.Stop()
}