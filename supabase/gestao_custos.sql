-- =====================================================================
-- Controle de Qualidade QC — Gestão de Custos
-- Rodar no SQL Editor do Supabase DEPOIS do schema.sql (pode repetir).
--
-- Regras:
-- * O custo de um código vale a partir da data de vigência informada pelo RH
--   e até a véspera da próxima vigência do mesmo código.
-- * Cada registro de descarte guarda o custo aplicado (custoUnit, custoId,
--   custoVigencia) e o prejuízo (Scrap × custoUnit). Novas importações não
--   mudam esses valores, a não ser com autorização explícita (recálculo).
-- * Só o administrador importa, corrige preços e fecha/reabre meses.
-- * Mês fechado: o banco recusa incluir, alterar ou excluir registros dele.
-- =====================================================================

-- ---------- Importações de planilhas de custo ----------
create table if not exists public.custos_importacoes (
  id                     bigint generated always as identity primary key,
  arquivo                text not null,
  aba                    text not null default '',
  hash                   text not null,
  vigencia               date not null,
  linhas                 int  not null default 0,
  inseridos              int  not null default 0,
  atualizados            int  not null default 0,
  sem_alteracao          int  not null default 0,
  ignorados              int  not null default 0,
  registros_preenchidos  int  not null default 0,
  registros_recalculados int  not null default 0,
  resumo                 jsonb,
  usuario_id             uuid default auth.uid() references auth.users(id) on delete set null,
  usuario_nome           text not null default '',
  em                     timestamptz not null default now()
);
-- A mesma aba do mesmo arquivo não pode ser importada duas vezes com a mesma vigência.
create unique index if not exists custos_importacoes_unica on public.custos_importacoes (hash, aba, vigencia);

-- ---------- Histórico de custos por código ----------
create table if not exists public.custos (
  id            bigint generated always as identity primary key,
  codigo        text not null check (codigo <> '' and codigo = upper(btrim(codigo))),
  modelo        text not null default '',
  custo         numeric(14,4) not null check (custo > 0),
  vigencia      date not null,
  importacao_id bigint references public.custos_importacoes(id) on delete set null,
  criado_por    uuid default auth.uid() references auth.users(id) on delete set null,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (codigo, vigencia)
);

-- ---------- Correções e recálculos (registro permanente) ----------
create table if not exists public.custos_correcoes (
  id                 bigint generated always as identity primary key,
  custo_id           bigint references public.custos(id) on delete set null,
  codigo             text not null,
  vigencia           date not null,
  valor_anterior     numeric(14,4),
  valor_novo         numeric(14,4),
  tipo               text not null check (tipo in ('correcao', 'recalculo', 'preenchimento')),
  motivo             text not null default '',
  registros_afetados int  not null default 0,
  importacao_id      bigint references public.custos_importacoes(id) on delete set null,
  usuario_id         uuid default auth.uid() references auth.users(id) on delete set null,
  usuario_nome       text not null default '',
  em                 timestamptz not null default now()
);

-- ---------- Fechamento mensal ----------
create table if not exists public.fechamentos (
  periodo        text primary key check (periodo ~ '^[0-9]{4}-[0-9]{2}$'),
  status         text not null check (status in ('fechado', 'aberto')),
  totais         jsonb,
  atualizado_por text not null default '',
  atualizado_em  timestamptz not null default now()
);
create table if not exists public.fechamentos_log (
  id           bigint generated always as identity primary key,
  periodo      text not null,
  acao         text not null check (acao in ('fechar', 'reabrir')),
  motivo       text not null default '',
  totais       jsonb,
  usuario_id   uuid default auth.uid() references auth.users(id) on delete set null,
  usuario_nome text not null default '',
  em           timestamptz not null default now()
);

-- ---------- Regras operacionais (ex.: foto da caixa obrigatória) ----------
create table if not exists public.regras (
  chave          text primary key,
  valor          jsonb,
  atualizado_por text not null default '',
  atualizado_em  timestamptz not null default now()
);

-- ---------- Segurança: todos os logados leem; só o admin grava ----------
alter table public.custos_importacoes enable row level security;
alter table public.custos             enable row level security;
alter table public.custos_correcoes   enable row level security;
alter table public.fechamentos        enable row level security;
alter table public.fechamentos_log    enable row level security;
alter table public.regras             enable row level security;

drop policy if exists "custos_importacoes: logados leem" on public.custos_importacoes;
create policy "custos_importacoes: logados leem" on public.custos_importacoes for select to authenticated using (true);
drop policy if exists "custos: logados leem" on public.custos;
create policy "custos: logados leem" on public.custos for select to authenticated using (true);
drop policy if exists "custos_correcoes: logados leem" on public.custos_correcoes;
create policy "custos_correcoes: logados leem" on public.custos_correcoes for select to authenticated using (true);
drop policy if exists "fechamentos: logados leem" on public.fechamentos;
create policy "fechamentos: logados leem" on public.fechamentos for select to authenticated using (true);
drop policy if exists "fechamentos_log: logados leem" on public.fechamentos_log;
create policy "fechamentos_log: logados leem" on public.fechamentos_log for select to authenticated using (true);
drop policy if exists "regras: logados leem" on public.regras;
create policy "regras: logados leem" on public.regras for select to authenticated using (true);
drop policy if exists "regras: admin grava" on public.regras;
create policy "regras: admin grava" on public.regras for insert to authenticated with check (public.is_admin());
drop policy if exists "regras: admin altera" on public.regras;
create policy "regras: admin altera" on public.regras for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- Custos, importações, correções e fechamentos só mudam pelas funções abaixo
-- (que conferem se quem pede é administrador). Nada é apagado.
revoke all on public.custos_importacoes, public.custos, public.custos_correcoes,
              public.fechamentos, public.fechamentos_log, public.regras from anon, authenticated;
grant select on public.custos_importacoes, public.custos, public.custos_correcoes,
                public.fechamentos, public.fechamentos_log, public.regras to authenticated;
grant insert, update on public.regras to authenticated;

-- ---------- Mês fechado bloqueia alterações nos registros ----------
create or replace function public.bloquear_mes_fechado() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and exists (
       select 1 from public.fechamentos
       where periodo = left(old.dados ->> 'date', 7) and status = 'fechado') then
    raise exception 'MES_FECHADO: o mês % está fechado. Peça ao administrador para reabrir.', left(old.dados ->> 'date', 7);
  end if;
  if tg_op in ('INSERT', 'UPDATE') and exists (
       select 1 from public.fechamentos
       where periodo = left(new.dados ->> 'date', 7) and status = 'fechado') then
    raise exception 'MES_FECHADO: o mês % está fechado. Peça ao administrador para reabrir.', left(new.dados ->> 'date', 7);
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
drop trigger if exists registros_mes_fechado on public.registros;
create trigger registros_mes_fechado
  before insert or update or delete on public.registros
  for each row execute function public.bloquear_mes_fechado();

-- ---------- Funções internas ----------
create or replace function public.qc_nome_usuario() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select nome from public.perfis where id = auth.uid()), '');
$$;

-- Aplica um preço aos registros do código dentro da vigência dele (sem tocar em meses fechados).
-- modo 'sem_custo'   : só registros que ainda não têm custo
-- modo 'mesmo_preco' : só registros que usaram este preço (correção de valor)
-- modo 'todos'       : registros da vigência que estão sem custo ou com outro custo
create or replace function public.qc_aplicar_preco(p_id bigint, p_modo text) returns int
language plpgsql security definer set search_path = public as $$
declare
  c record;
  v_ini text;
  v_fim text;
  n int;
begin
  select * into c from public.custos where id = p_id;
  if not found then return 0; end if;
  v_ini := to_char(c.vigencia, 'YYYY-MM-DD');
  select to_char(min(vigencia), 'YYYY-MM-DD') into v_fim
    from public.custos where codigo = c.codigo and vigencia > c.vigencia;
  update public.registros r
     set dados = r.dados || jsonb_build_object(
           'custoUnit', c.custo,
           'custoId', c.id,
           'custoVigencia', v_ini,
           'prejuizo', round(coalesce(nullif(r.dados ->> 'ng', '')::numeric, 0) * c.custo, 2))
   where upper(btrim(coalesce(r.dados ->> 'code', ''))) = c.codigo
     and r.dados ->> 'date' >= v_ini
     and (v_fim is null or r.dados ->> 'date' < v_fim)
     and not exists (select 1 from public.fechamentos f
                      where f.periodo = left(r.dados ->> 'date', 7) and f.status = 'fechado')
     and case p_modo
           when 'sem_custo'   then coalesce(r.dados ->> 'custoUnit', '') = ''
           when 'mesmo_preco' then r.dados ->> 'custoId' = c.id::text
           else coalesce(r.dados ->> 'custoUnit', '') = ''
                or r.dados ->> 'custoId' is distinct from c.id::text
                or nullif(r.dados ->> 'custoUnit', '')::numeric is distinct from c.custo
         end;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke execute on function public.qc_aplicar_preco(bigint, text) from public, anon, authenticated;

-- ---------- Prévia do impacto de uma importação (somente leitura) ----------
create or replace function public.custos_previa(p_vigencia date, p_codigos text[]) returns jsonb
language sql stable security definer set search_path = public as $$
  with cod as (
    select distinct upper(btrim(x)) as c from unnest(p_codigos) x where btrim(coalesce(x, '')) <> ''
  ), lim as (
    select cod.c,
           (select min(k.vigencia) from public.custos k where k.codigo = cod.c and k.vigencia > p_vigencia) as fim,
           (select k.id from public.custos k where k.codigo = cod.c and k.vigencia = p_vigencia) as mesmo_id
      from cod
  ), reg as (
    select upper(btrim(coalesce(r.dados ->> 'code', ''))) as c,
           r.dados ->> 'date' as d,
           coalesce(r.dados ->> 'custoUnit', '') as cu,
           r.dados ->> 'custoId' as ci,
           exists (select 1 from public.fechamentos f
                    where f.periodo = left(r.dados ->> 'date', 7) and f.status = 'fechado') as fechado
      from public.registros r
     where upper(btrim(coalesce(r.dados ->> 'code', ''))) in (select c from cod)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'codigo', lim.c,
    'em_registros', exists (select 1 from reg where reg.c = lim.c),
    'proxima_vigencia', lim.fim,
    'sem_custo',   (select count(*) from reg where reg.c = lim.c and not reg.fechado and reg.cu = ''
                      and reg.d >= to_char(p_vigencia, 'YYYY-MM-DD') and (lim.fim is null or reg.d < to_char(lim.fim, 'YYYY-MM-DD'))),
    'mesmo_preco', (select count(*) from reg where reg.c = lim.c and not reg.fechado and reg.cu <> ''
                      and lim.mesmo_id is not null and reg.ci = lim.mesmo_id::text),
    'outro_custo', (select count(*) from reg where reg.c = lim.c and not reg.fechado and reg.cu <> ''
                      and reg.ci is distinct from coalesce(lim.mesmo_id::text, '')
                      and reg.d >= to_char(p_vigencia, 'YYYY-MM-DD') and (lim.fim is null or reg.d < to_char(lim.fim, 'YYYY-MM-DD'))),
    'fechados',    (select count(*) from reg where reg.c = lim.c and reg.fechado
                      and reg.d >= to_char(p_vigencia, 'YYYY-MM-DD') and (lim.fim is null or reg.d < to_char(lim.fim, 'YYYY-MM-DD')))
  )), '[]'::jsonb)
  from lim;
$$;
revoke execute on function public.custos_previa(date, text[]) from public, anon;
grant execute on function public.custos_previa(date, text[]) to authenticated;

-- ---------- Importação (tudo ou nada, numa única transação) ----------
-- p = { arquivo, aba, hash, vigencia 'AAAA-MM-DD', linhas, ignorados, resumo,
--       itens: [{codigo, modelo, custo}], preencher bool, recalcular bool, motivo }
create or replace function public.importar_custos(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_vig   date := nullif(p ->> 'vigencia', '')::date;
  v_pre   boolean := coalesce((p ->> 'preencher')::boolean, false);
  v_rec   boolean := coalesce((p ->> 'recalcular')::boolean, false);
  v_mot   text := btrim(coalesce(p ->> 'motivo', ''));
  v_nome  text := public.qc_nome_usuario();
  v_imp   bigint;
  it      jsonb;
  ex      record;
  v_cod   text;
  v_mod   text;
  v_val   numeric;
  v_id    bigint;
  k       int;
  n_ins   int := 0;
  n_upd   int := 0;
  n_eq    int := 0;
  n_pre   int := 0;
  n_rec   int := 0;
begin
  if not public.is_admin() then raise exception 'Somente o administrador pode importar custos.'; end if;
  if v_vig is null then raise exception 'Informe a data de vigência dos custos.'; end if;
  if v_rec and v_mot = '' then raise exception 'Informe o motivo do recálculo retroativo.'; end if;
  if coalesce(p ->> 'hash', '') = '' then raise exception 'Arquivo sem identificação (hash).'; end if;
  if exists (select 1 from public.custos_importacoes
              where hash = p ->> 'hash' and aba = coalesce(p ->> 'aba', '') and vigencia = v_vig) then
    raise exception 'IMPORTACAO_DUPLICADA: esta aba deste arquivo já foi importada com vigência %.', to_char(v_vig, 'DD/MM/YYYY');
  end if;

  insert into public.custos_importacoes (arquivo, aba, hash, vigencia, linhas, ignorados, resumo, usuario_nome)
  values (coalesce(p ->> 'arquivo', ''), coalesce(p ->> 'aba', ''), p ->> 'hash', v_vig,
          coalesce((p ->> 'linhas')::int, 0), coalesce((p ->> 'ignorados')::int, 0), p -> 'resumo', v_nome)
  returning id into v_imp;

  for it in select * from jsonb_array_elements(coalesce(p -> 'itens', '[]'::jsonb)) loop
    v_cod := upper(btrim(coalesce(it ->> 'codigo', '')));
    v_mod := btrim(coalesce(it ->> 'modelo', ''));
    v_val := nullif(it ->> 'custo', '')::numeric;
    if v_cod = '' or v_val is null or v_val <= 0 then
      raise exception 'Item inválido na importação: código "%" custo "%".', v_cod, it ->> 'custo';
    end if;

    select * into ex from public.custos where codigo = v_cod and vigencia = v_vig;
    if not found then
      insert into public.custos (codigo, modelo, custo, vigencia, importacao_id)
      values (v_cod, v_mod, v_val, v_vig, v_imp) returning id into v_id;
      n_ins := n_ins + 1;
    elsif ex.custo <> v_val then
      v_id := ex.id;
      update public.custos set custo = v_val, modelo = coalesce(nullif(v_mod, ''), modelo),
             importacao_id = v_imp, atualizado_em = now() where id = v_id;
      insert into public.custos_correcoes (custo_id, codigo, vigencia, valor_anterior, valor_novo, tipo, motivo, importacao_id, usuario_nome)
      values (v_id, v_cod, v_vig, ex.custo, v_val, 'correcao',
              coalesce(nullif(v_mot, ''), 'Nova importação com valor diferente para a mesma vigência'), v_imp, v_nome);
      n_upd := n_upd + 1;
    else
      v_id := ex.id;
      n_eq := n_eq + 1;
    end if;

    if v_pre then
      k := public.qc_aplicar_preco(v_id, 'sem_custo');
      if k > 0 then
        n_pre := n_pre + k;
        insert into public.custos_correcoes (custo_id, codigo, vigencia, valor_novo, tipo, motivo, registros_afetados, importacao_id, usuario_nome)
        values (v_id, v_cod, v_vig, v_val, 'preenchimento', 'Registros sem custo recebem o custo vigente', k, v_imp, v_nome);
      end if;
    end if;
    if v_rec then
      k := public.qc_aplicar_preco(v_id, 'todos');
      if k > 0 then
        n_rec := n_rec + k;
        insert into public.custos_correcoes (custo_id, codigo, vigencia, valor_novo, tipo, motivo, registros_afetados, importacao_id, usuario_nome)
        values (v_id, v_cod, v_vig, v_val, 'recalculo', v_mot, k, v_imp, v_nome);
      end if;
    end if;
  end loop;

  update public.custos_importacoes
     set inseridos = n_ins, atualizados = n_upd, sem_alteracao = n_eq,
         registros_preenchidos = n_pre, registros_recalculados = n_rec
   where id = v_imp;

  return jsonb_build_object('importacao_id', v_imp, 'inseridos', n_ins, 'atualizados', n_upd,
                            'sem_alteracao', n_eq, 'preenchidos', n_pre, 'recalculados', n_rec,
                            'usuario', v_nome, 'em', now());
end;
$$;
revoke execute on function public.importar_custos(jsonb) from public, anon;
grant execute on function public.importar_custos(jsonb) to authenticated;

-- ---------- Correção de um preço já gravado ----------
create or replace function public.corrigir_custo(p_id bigint, p_valor numeric, p_motivo text, p_recalcular boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c record;
  v_nome text := public.qc_nome_usuario();
  k int := 0;
begin
  if not public.is_admin() then raise exception 'Somente o administrador pode corrigir custos.'; end if;
  if btrim(coalesce(p_motivo, '')) = '' then raise exception 'Informe o motivo da correção.'; end if;
  if p_valor is null or p_valor <= 0 then raise exception 'O custo deve ser maior que zero.'; end if;
  select * into c from public.custos where id = p_id for update;
  if not found then raise exception 'Preço não encontrado.'; end if;
  if c.custo = p_valor then raise exception 'O valor informado é igual ao atual.'; end if;
  update public.custos set custo = p_valor, atualizado_em = now() where id = p_id;
  insert into public.custos_correcoes (custo_id, codigo, vigencia, valor_anterior, valor_novo, tipo, motivo, usuario_nome)
  values (p_id, c.codigo, c.vigencia, c.custo, p_valor, 'correcao', btrim(p_motivo), v_nome);
  if p_recalcular then
    k := public.qc_aplicar_preco(p_id, 'mesmo_preco');
    if k > 0 then
      insert into public.custos_correcoes (custo_id, codigo, vigencia, valor_anterior, valor_novo, tipo, motivo, registros_afetados, usuario_nome)
      values (p_id, c.codigo, c.vigencia, c.custo, p_valor, 'recalculo', btrim(p_motivo), k, v_nome);
    end if;
  end if;
  return jsonb_build_object('recalculados', k);
end;
$$;
revoke execute on function public.corrigir_custo(bigint, numeric, text, boolean) from public, anon;
grant execute on function public.corrigir_custo(bigint, numeric, text, boolean) to authenticated;

-- ---------- Registros sem custo recebem o custo vigente na data deles ----------
create or replace function public.aplicar_custos_sem_valor(p_de date, p_ate date) returns int
language plpgsql security definer set search_path = public as $$
declare
  n int;
begin
  if not public.is_admin() then raise exception 'Somente o administrador pode aplicar custos.'; end if;
  with alvo as (
    select r.id, k.id as kid, k.custo, k.vigencia
      from public.registros r
      join lateral (
        select c.id, c.custo, c.vigencia from public.custos c
         where c.codigo = upper(btrim(coalesce(r.dados ->> 'code', '')))
           and to_char(c.vigencia, 'YYYY-MM-DD') <= r.dados ->> 'date'
         order by c.vigencia desc limit 1) k on true
     where r.dados ->> 'date' between to_char(p_de, 'YYYY-MM-DD') and to_char(p_ate, 'YYYY-MM-DD')
       and coalesce(r.dados ->> 'custoUnit', '') = ''
       and not exists (select 1 from public.fechamentos f
                        where f.periodo = left(r.dados ->> 'date', 7) and f.status = 'fechado')
  )
  update public.registros r
     set dados = r.dados || jsonb_build_object(
           'custoUnit', alvo.custo, 'custoId', alvo.kid, 'custoVigencia', to_char(alvo.vigencia, 'YYYY-MM-DD'),
           'prejuizo', round(coalesce(nullif(r.dados ->> 'ng', '')::numeric, 0) * alvo.custo, 2))
    from alvo where r.id = alvo.id;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke execute on function public.aplicar_custos_sem_valor(date, date) from public, anon;
grant execute on function public.aplicar_custos_sem_valor(date, date) to authenticated;

-- ---------- Fechar e reabrir mês ----------
create or replace function public.fechar_mes(p_periodo text, p_totais jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_nome text := public.qc_nome_usuario();
begin
  if not public.is_admin() then raise exception 'Somente o administrador pode fechar o mês.'; end if;
  if p_periodo !~ '^[0-9]{4}-[0-9]{2}$' then raise exception 'Período inválido.'; end if;
  insert into public.fechamentos (periodo, status, totais, atualizado_por, atualizado_em)
  values (p_periodo, 'fechado', p_totais, v_nome, now())
  on conflict (periodo) do update set status = 'fechado', totais = excluded.totais,
                                      atualizado_por = excluded.atualizado_por, atualizado_em = now();
  insert into public.fechamentos_log (periodo, acao, totais, usuario_nome) values (p_periodo, 'fechar', p_totais, v_nome);
end;
$$;
revoke execute on function public.fechar_mes(text, jsonb) from public, anon;
grant execute on function public.fechar_mes(text, jsonb) to authenticated;

create or replace function public.reabrir_mes(p_periodo text, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare v_nome text := public.qc_nome_usuario();
begin
  if not public.is_admin() then raise exception 'Somente o administrador pode reabrir o mês.'; end if;
  if btrim(coalesce(p_motivo, '')) = '' then raise exception 'Informe o motivo da reabertura.'; end if;
  update public.fechamentos set status = 'aberto', atualizado_por = v_nome, atualizado_em = now()
   where periodo = p_periodo and status = 'fechado';
  if not found then raise exception 'Este mês não está fechado.'; end if;
  insert into public.fechamentos_log (periodo, acao, motivo, usuario_nome) values (p_periodo, 'reabrir', btrim(p_motivo), v_nome);
end;
$$;
revoke execute on function public.reabrir_mes(text, text) from public, anon;
grant execute on function public.reabrir_mes(text, text) to authenticated;

revoke execute on function public.qc_nome_usuario() from public, anon;
grant execute on function public.qc_nome_usuario() to authenticated;
