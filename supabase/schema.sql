-- =====================================================================
-- Controle de Qualidade QC — banco de dados no Supabase
-- Rodar uma vez no SQL Editor do projeto.
-- =====================================================================

-- ---------- Perfis (quem é admin ou usuário) ----------
create table if not exists public.perfis (
  id        uuid primary key references auth.users(id) on delete cascade,
  email     text not null,
  nome      text not null default '',
  papel     text not null default 'user' check (papel in ('admin', 'user')),
  criado_em timestamptz not null default now()
);

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where id = auth.uid() and papel = 'admin');
$$;

-- Cria o perfil automaticamente quando uma conta é criada.
-- A primeira conta do sistema vira administrador.
-- O papel vem de app_metadata, que só o servidor (Edge Function) pode definir.
create or replace function public.criar_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfis (id, email, nome, papel)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'nome', split_part(new.email, '@', 1)),
    case
      when not exists (select 1 from public.perfis) then 'admin'
      when new.raw_app_meta_data ->> 'papel' = 'admin' then 'admin'
      else 'user'
    end
  );
  return new;
end;
$$;

drop trigger if exists ao_criar_usuario on auth.users;
create trigger ao_criar_usuario
  after insert on auth.users
  for each row execute function public.criar_perfil();

alter table public.perfis enable row level security;
drop policy if exists "perfis: logados leem" on public.perfis;
create policy "perfis: logados leem" on public.perfis
  for select to authenticated using (true);
drop policy if exists "perfis: admin altera" on public.perfis;
create policy "perfis: admin altera" on public.perfis
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---------- Registros de qualidade ----------
-- "dados" guarda o registro inteiro, com os mesmos campos do sistema.
create table if not exists public.registros (
  id            bigint primary key,
  tab_id        text not null default 'main',
  dados         jsonb not null,
  criado_por    uuid default auth.uid() references auth.users(id) on delete set null,
  atualizado_em timestamptz not null default now()
);
create index if not exists registros_tab_id on public.registros (tab_id);

create or replace function public.marcar_atualizacao() returns trigger
language plpgsql as $$
begin
  new.atualizado_em = now();
  return new;
end;
$$;

drop trigger if exists registros_atualizado on public.registros;
create trigger registros_atualizado
  before update on public.registros
  for each row execute function public.marcar_atualizacao();

alter table public.registros enable row level security;
drop policy if exists "registros: logados leem" on public.registros;
create policy "registros: logados leem" on public.registros
  for select to authenticated using (true);
drop policy if exists "registros: logados inserem" on public.registros;
create policy "registros: logados inserem" on public.registros
  for insert to authenticated with check (true);
drop policy if exists "registros: logados alteram" on public.registros;
create policy "registros: logados alteram" on public.registros
  for update to authenticated using (true) with check (true);
drop policy if exists "registros: logados excluem" on public.registros;
create policy "registros: logados excluem" on public.registros
  for delete to authenticated using (true);

-- ---------- Configurações (abas de registros, índice de fotos) ----------
create table if not exists public.config (
  chave         text primary key,
  valor         jsonb,
  atualizado_em timestamptz not null default now()
);

drop trigger if exists config_atualizado on public.config;
create trigger config_atualizado
  before update on public.config
  for each row execute function public.marcar_atualizacao();

alter table public.config enable row level security;
drop policy if exists "config: logados leem" on public.config;
create policy "config: logados leem" on public.config
  for select to authenticated using (true);
drop policy if exists "config: logados inserem" on public.config;
create policy "config: logados inserem" on public.config
  for insert to authenticated with check (true);
drop policy if exists "config: logados alteram" on public.config;
create policy "config: logados alteram" on public.config
  for update to authenticated using (true) with check (true);

-- ---------- Histórico de acessos ----------
-- Cada pessoa só registra o próprio login/logout; só o admin lê.
-- Tentativas de senha errada ficam nos logs de Auth do Supabase.
create table if not exists public.acessos (
  id         bigint generated always as identity primary key,
  em         timestamptz not null default now(),
  usuario_id uuid default auth.uid() references auth.users(id) on delete set null,
  email      text not null,
  nome       text not null default '',
  evento     text not null check (evento in ('login', 'logout'))
);

alter table public.acessos enable row level security;
drop policy if exists "acessos: registra o próprio" on public.acessos;
create policy "acessos: registra o próprio" on public.acessos
  for insert to authenticated with check (usuario_id = auth.uid());
drop policy if exists "acessos: admin lê" on public.acessos;
create policy "acessos: admin lê" on public.acessos
  for select to authenticated using (public.is_admin());

-- ---------- Permissões ----------
revoke all on public.perfis, public.registros, public.config, public.acessos from anon;
grant select, update                 on public.perfis    to authenticated;
grant select, insert, update, delete on public.registros to authenticated;
grant select, insert, update         on public.config    to authenticated;
grant select, insert                 on public.acessos   to authenticated;
revoke execute on function public.is_admin() from anon;
grant execute on function public.is_admin() to authenticated;

-- ---------- Tempo real ----------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and tablename = 'registros') then
    alter publication supabase_realtime add table public.registros;
  end if;
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and tablename = 'config') then
    alter publication supabase_realtime add table public.config;
  end if;
end;
$$;

-- ---------- Fotos (Storage privado) ----------
insert into storage.buckets (id, name, public)
values ('fotos', 'fotos', false)
on conflict (id) do nothing;

drop policy if exists "fotos: logados leem" on storage.objects;
create policy "fotos: logados leem" on storage.objects
  for select to authenticated using (bucket_id = 'fotos');
drop policy if exists "fotos: logados enviam" on storage.objects;
create policy "fotos: logados enviam" on storage.objects
  for insert to authenticated with check (bucket_id = 'fotos');
drop policy if exists "fotos: logados substituem" on storage.objects;
create policy "fotos: logados substituem" on storage.objects
  for update to authenticated using (bucket_id = 'fotos') with check (bucket_id = 'fotos');
drop policy if exists "fotos: logados excluem" on storage.objects;
create policy "fotos: logados excluem" on storage.objects
  for delete to authenticated using (bucket_id = 'fotos');
