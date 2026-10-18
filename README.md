# Controle de Qualidade QC — Dashboard

Sistema web para registro e análise de controle de qualidade, feito em um único arquivo HTML.

**Acesse:** https://das-controle-qualidade.github.io/

## Funcionalidades

- Dashboard com indicadores
- Registros com abas personalizáveis e fotos
- Pareto & Rankings
- Análises por período e visão por mês
- Relatório executivo
- Importação de planilhas Excel (.xlsx) e CSV
- Backup e restauração dos dados
- Controle de acessos (administrador e usuário)
- Idiomas: Português, English, Español, 한국어

## Como usar

Abra o `index.html` no navegador, ou acesse a versão publicada pelo GitHub Pages.
No primeiro acesso, crie a conta de administrador.

## Onde os dados ficam

Hoje os registros e usuários ficam salvos **no navegador de cada computador**
(IndexedDB e localStorage). Eles não são compartilhados entre pessoas ou dispositivos.
Use **Dados & Backup** para exportar uma cópia regularmente.

## Próximos passos

- [ ] Login real e banco de dados na nuvem (Supabase ou Firebase) para compartilhar dados entre a equipe
