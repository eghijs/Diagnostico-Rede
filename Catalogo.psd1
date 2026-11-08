<#
Proprietário, nome: Erik Pereira Ghijs
Contato: eghijs@gmail.com

Organização, projeto: NexusCloud Toolbox
Finalidade do script: Cadastrar os serviços disponíveis na interface.
Ambiente previsto: Windows 10 e Windows 11, Windows PowerShell 5.1.
Classificação: Uso interno, confidencial
Controle de versão: Versão 0.2.5, data 08-11-2026

Aviso legal: Script de propriedade exclusiva do autor.
Uso restrito ao ambiente interno autorizado.
Proibida cópia, redistribuição, modificação ou uso sem autorização formal.
Uso indevido sujeito a sanções legais.

Checklist de segurança: SHA-256 obrigatório por ferramenta.
Elevação administrativa somente quando indicada.
Logs fornecidos pelo executor e pelas ferramentas.
DryRun disponível conforme implementação de cada serviço.
#>

@{
    Versao = '0.2.5'

    Ferramentas = @(
        @{
            Id                   = 'diagnostico-rede'
            Nome                 = 'Diagnóstico de rede'
            Categoria            = 'Rede'
            Descricao            = 'Abre a coleta de hostname, MAC Wi-Fi, MAC cabo e data. Utilize Coletar e Salvar relatório na janela do diagnóstico.'
            Versao               = '1.1.0'
            Arquivo              = 'Diagnostico-Rede.ps1'
            SHA256               = 'E35EB5EA5831ACB899D2DAF68A0D4E9656C155E76E92B22CD311AC3DCD2E75B3'
            ExigeAdministrador   = $false
            PermiteSimulacao     = $true
            ParametrosPermitidos = @('DryRun')
        }

        @{
            Id                   = 'bloquear-hotspot-windows'
            Nome                 = 'Bloquear Hotspot Windows'
            Categoria            = 'Ferramentas'
            Descricao            = 'Bloqueia Hotspot, compartilhamento de internet, Hosted Network e Bluetooth PAN. Exige autorização de administrador.'
            Versao               = '2.1.0'
            Arquivo              = 'BloquearHotspotWindows_v2.1.ps1'
            SHA256               = '9C4D2431AF09FEF81B071CA7FC2C008F5EC032A249CF5726010A651EA3034A6E'
            ExigeAdministrador   = $true
            PermiteSimulacao     = $true
            ParametrosPermitidos = @('DryRun')
        }
    )
}