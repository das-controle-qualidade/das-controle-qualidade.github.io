-- =====================================================================
-- Teste da Gestão de Custos no banco real — NÃO grava nada.
-- Rodar no SQL Editor depois do gestao_custos.sql. Tudo acontece dentro de
-- um bloco que termina com erro de propósito: o Postgres desfaz todas as
-- alterações e a mensagem do erro mostra o resultado de cada verificação.
-- =====================================================================
do $$
declare
  v_admin uuid := (select id from public.perfis where papel = 'admin' order by criado_em limit 1);
  r jsonb;
  ok text := '';
  n int;
  v numeric;
  v_id bigint;
begin
  if v_admin is null then raise exception 'Nenhum administrador em perfis.'; end if;
  -- age como o administrador (o mesmo que o site faz com o login)
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  -- registros fictícios em 2031 (não existem dados reais nessa data)
  insert into public.registros (id, tab_id, dados) values
    (990000001, 'main', '{"date":"2031-01-10","code":"TESTE-QC-1","model":"MODELO TESTE","problem":"t","ng":5,"re":0}'),
    (990000002, 'main', '{"date":"2031-02-03","code":"teste-qc-1 ","model":"MODELO TESTE","problem":"t","ng":4,"re":0}'),
    (990000003, 'main', '{"date":"2031-02-28","code":"TESTE-QC-2","model":"OUTRO","problem":"t","ng":3,"re":0}'),
    (990000004, 'main', '{"date":"2031-03-01","code":"SEM-PRECO","model":"X","problem":"t","ng":2,"re":0}');

  -- 1) importação de janeiro preenche os registros sem custo
  r := public.importar_custos('{"arquivo":"teste.xlsx","aba":"Janeiro","hash":"hash-teste","vigencia":"2031-01-01",
        "itens":[{"codigo":"TESTE-QC-1","modelo":"MODELO TESTE","custo":10},{"codigo":"TESTE-QC-2","modelo":"OUTRO","custo":45}],
        "preencher":true}');
  ok := ok || format('[1] inseridos=%s preenchidos=%s (esperado 2 e 3) ', r->>'inseridos', r->>'preenchidos');
  select (dados->>'prejuizo')::numeric into v from public.registros where id = 990000001;
  ok := ok || format('[1b] prejuízo 5x10=%s ', v);

  -- 2) importação duplicada é recusada
  begin
    perform public.importar_custos('{"arquivo":"teste.xlsx","aba":"Janeiro","hash":"hash-teste","vigencia":"2031-01-01","itens":[{"codigo":"TESTE-QC-1","custo":10}]}');
    ok := ok || '[2] FALHOU: duplicada aceita ';
  exception when others then ok := ok || '[2] duplicada recusada ';
  end;

  -- 3) fevereiro sem autorização não muda registros já com custo
  r := public.custos_previa('2031-02-01', array['TESTE-QC-1']);
  ok := ok || format('[3a] prévia outro_custo=%s (esperado 1) ', r->0->>'outro_custo');
  r := public.importar_custos('{"arquivo":"teste.xlsx","aba":"Fevereiro","hash":"hash-teste","vigencia":"2031-02-01","itens":[{"codigo":"TESTE-QC-1","custo":15}],"preencher":true}');
  select (dados->>'custoUnit')::numeric into v from public.registros where id = 990000002;
  ok := ok || format('[3b] registro de fev mantém custo=%s (esperado 10) ', v);

  -- 4) correção com recálculo autorizado altera só quem usou o preço, dentro da vigência
  select id into v_id from public.custos where codigo = 'TESTE-QC-1' and vigencia = '2031-01-01';
  r := public.corrigir_custo(v_id, 12, 'teste', true);
  select (dados->>'prejuizo')::numeric into v from public.registros where id = 990000001;
  ok := ok || format('[4] recalculados=%s prejuízo jan=%s (esperado 1 e 60) ', r->>'recalculados', v);

  -- 5) aplicar custo a registros sem custo: SEM-PRECO continua sem custo
  n := public.aplicar_custos_sem_valor('2031-01-01', '2031-12-31');
  ok := ok || format('[5] aplicados=%s (esperado 0) ', n);

  -- 6) mês fechado bloqueia alteração e exclusão
  perform public.fechar_mes('2031-02', '{"teste":true}');
  begin
    update public.registros set dados = dados || '{"obs":"x"}' where id = 990000003;
    ok := ok || '[6] FALHOU: alterou mês fechado ';
  exception when others then ok := ok || '[6] mês fechado bloqueou alteração ';
  end;
  begin
    delete from public.registros where id = 990000003;
    ok := ok || '[6b] FALHOU: excluiu mês fechado ';
  exception when others then ok := ok || '[6b] bloqueou exclusão ';
  end;
  begin
    perform public.reabrir_mes('2031-02', '');
    ok := ok || '[7] FALHOU: reabriu sem motivo ';
  exception when others then ok := ok || '[7] reabrir exige motivo ';
  end;
  perform public.reabrir_mes('2031-02', 'teste');
  update public.registros set dados = dados || '{"obs":"x"}' where id = 990000003;
  ok := ok || '[7b] reaberto aceita alteração ';

  -- 8) usuário comum não importa
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}', true);
  begin
    perform public.importar_custos('{"arquivo":"x","aba":"x","hash":"x2","vigencia":"2031-05-01","itens":[]}');
    ok := ok || '[8] FALHOU: não-admin importou ';
  exception when others then ok := ok || '[8] não-admin recusado ';
  end;

  raise exception 'RESULTADO DO TESTE (nada foi gravado): %', ok;
end;
$$;
