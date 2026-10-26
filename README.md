# Controle de Qualidade QC — Dashboard

Sistema web para registro e análise de controle de qualidade, feito em um único arquivo HTML.

**Acesse:** https://das-controle-qualidade.github.io/

## Funcionalidades

- Dashboard com indicadores
- Registros com abas personalizáveis, foto do problema e foto da caixa na balança
- Pareto & Rankings
- Análises por período e visão por mês
- Relatório executivo
- Gestão de Custos: importação mensal da planilha de custos, histórico de preços com vigência,
  prejuízo dos descartes (Scrap × custo vigente na data), fechamento semanal/mensal/anual
- Importação de planilhas Excel (.xlsx) e CSV
- Backup e restauração dos dados
- Controle de acessos (administrador e usuário)
- Idiomas: Português, English, Español, 한국어

## Como usar

Abra o `index.html` no navegador, ou acesse a versão publicada pelo GitHub Pages.
No primeiro acesso, crie a conta de administrador.

## Onde os dados ficam

Os registros, fotos e custos ficam no Supabase e são os mesmos para todos os usuários logados.
Use **Dados & Backup** para exportar uma cópia regularmente.

## Banco de dados

1. `supabase/schema.sql` — tabelas, segurança e fotos.
2. `supabase/gestao_custos.sql` — custos com vigência, importações, correções, fechamento mensal e regras.
3. `supabase/teste_gestao_custos.sql` — confere as regras de custo no banco sem gravar nada.
