-- =====================================================================
-- Gestão de Servidores – cor dos locais, jornada, histórico e atestados (19/11/2026)
--
-- O que faz:
--   1. locais.cor: cor de cada local (gráfico "Servidores por Local" e etiquetas).
--   2. servidores: cargo/função, vínculo, data de admissão, carga horária
--      semanal e expediente (horário de cada dia da semana, em JSON).
--   3. historico_servidor: histórico de serviço. O administrador lança
--      anotações; mudanças de lotação, cargo, vínculo e jornada entram
--      sozinhas (gatilho registrar_historico_servidor; o primeiro
--      preenchimento não conta como mudança). Só administradores leem e
--      gravam. renomear_local_servidores: renomeia o local nos servidores
--      sem registrar "troca de lotação".
--      Atenção: excluir um servidor apaga junto o histórico e os atestados
--      dele (on delete cascade); o site avisa antes de excluir.
--   4. atestados: o servidor envia o próprio atestado (PDF ou imagem, até
--      cerca de 4 MB); só ele e os administradores veem. O servidor cancela
--      enquanto o atestado não foi conferido; o administrador confere ou recusa.
--      O gatilho normalizar_atestado_servidor preenche autor, data e dias.
--
-- Depende de: 20261117_solicitacoes_servidor (função meu_servidor_id).
-- Ordem: aplicar ANTES de publicar o index.html novo. A versão anterior do
-- site continua funcionando (não usa as colunas nem as tabelas novas).
--
-- Dado de saúde (LGPD, art. 11): a tabela atestados guarda dado pessoal
-- sensível. Acesso restrito por RLS ao próprio servidor e aos administradores.
--
-- Para desfazer (apaga históricos e atestados gravados):
--   drop table public.atestados;
--   drop function public.normalizar_atestado_servidor();
--   drop function public.renomear_local_servidores(text, text);
--   drop trigger registrar_historico_servidor on public.servidores;
--   drop function public.registrar_historico_servidor();
--   drop table public.historico_servidor;
--   alter table public.servidores drop column cargo, drop column vinculo,
--     drop column data_admissao, drop column carga_horaria_semanal,
--     drop column expediente;
--   alter table public.locais drop column cor;
-- =====================================================================
begin;

-- 1. Cor de cada local
alter table public.locais add column if not exists cor text;
alter table public.locais drop constraint if exists locais_cor_formato;
alter table public.locais add constraint locais_cor_formato
  check (cor is null or cor ~ '^#[0-9a-fA-F]{6}$');

-- 2. Dados funcionais e jornada
alter table public.servidores
  add column if not exists cargo text,
  add column if not exists vinculo text,
  add column if not exists data_admissao date,
  add column if not exists carga_horaria_semanal smallint,
  add column if not exists expediente jsonb;
alter table public.servidores drop constraint if exists servidores_jornada_valida;
alter table public.servidores add constraint servidores_jornada_valida check (
  (cargo is null or length(cargo) <= 120)
  and (vinculo is null or length(vinculo) <= 40)
  and (carga_horaria_semanal is null or carga_horaria_semanal between 1 and 60)
  and (expediente is null or jsonb_typeof(expediente) = 'object')
);

-- 3. Histórico de serviço
create table if not exists public.historico_servidor (
  id bigint generated always as identity primary key,
  servidor_id bigint not null references public.servidores(id) on delete cascade,
  data date not null default ((now() at time zone 'America/Sao_Paulo')::date),
  tipo text not null check (tipo in ('admissao', 'lotacao', 'cargo', 'vinculo', 'jornada',
                                     'declaracao', 'anotacao', 'desligamento')),
  descricao text not null check (length(descricao) between 1 and 1000),
  automatico boolean not null default false,
  criado_por text not null default '',
  autor_uid uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists historico_servidor_servidor_data
  on public.historico_servidor (servidor_id, data desc);

alter table public.historico_servidor enable row level security;
drop policy if exists historico_admin_all on public.historico_servidor;
create policy historico_admin_all on public.historico_servidor
  for all to authenticated
  using (public.is_admin_or_above())
  with check (public.is_admin_or_above());

-- Mudanças de lotação, cargo, vínculo e jornada entram no histórico sozinhas.
-- O primeiro preenchimento (valor antigo vazio) não conta como mudança, e a
-- renomeação de um local (função renomear_local_servidores) não conta como troca de lotação.
create or replace function public.registrar_historico_servidor()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_quem text;
  v_carga_mudou boolean;
  v_exp_mudou boolean;
begin
  select u.nome into v_quem from public.users u where u.auth_uid = auth.uid() limit 1;
  v_quem := coalesce(v_quem, 'Sistema');

  if new.local is distinct from old.local
     and coalesce(current_setting('app.renomeando_local', true), '') <> 'on' then
    insert into public.historico_servidor (servidor_id, tipo, descricao, automatico, criado_por)
    values (new.id, 'lotacao',
            'Lotação: ' || coalesce(nullif(old.local, ''), '—') || ' → ' || coalesce(nullif(new.local, ''), '—'),
            true, v_quem);
  end if;
  if nullif(old.cargo, '') is not null and new.cargo is distinct from old.cargo then
    insert into public.historico_servidor (servidor_id, tipo, descricao, automatico, criado_por)
    values (new.id, 'cargo',
            'Cargo/função: ' || old.cargo || ' → ' || coalesce(nullif(new.cargo, ''), '—'),
            true, v_quem);
  end if;
  if nullif(old.vinculo, '') is not null and new.vinculo is distinct from old.vinculo then
    insert into public.historico_servidor (servidor_id, tipo, descricao, automatico, criado_por)
    values (new.id, 'vinculo',
            'Vínculo: ' || old.vinculo || ' → ' || coalesce(nullif(new.vinculo, ''), '—'),
            true, v_quem);
  end if;
  v_carga_mudou := old.carga_horaria_semanal is not null and new.carga_horaria_semanal is distinct from old.carga_horaria_semanal;
  v_exp_mudou := old.expediente is not null and new.expediente is distinct from old.expediente;
  if v_carga_mudou or v_exp_mudou then
    insert into public.historico_servidor (servidor_id, tipo, descricao, automatico, criado_por)
    values (new.id, 'jornada',
            'Jornada alterada'
            || case when v_carga_mudou
                    then ': carga horária ' || old.carga_horaria_semanal::text || ' h → '
                         || coalesce(new.carga_horaria_semanal::text || ' h', '—') || ' semanais'
                    else ': horário de expediente' end,
            true, v_quem);
  end if;
  return new;
end;
$fn$;

drop trigger if exists registrar_historico_servidor on public.servidores;
create trigger registrar_historico_servidor
  after update on public.servidores
  for each row execute function public.registrar_historico_servidor();

-- Renomear um local leva o nome novo aos servidores e às férias sem gerar
-- "troca de lotação" no histórico (o site chama esta função ao renomear)
create or replace function public.renomear_local_servidores(p_antigo text, p_novo text)
returns integer
language plpgsql
set search_path = ''
as $fn$
declare
  n integer;
begin
  if not public.is_admin_or_above() then
    raise exception 'Apenas administradores podem renomear locais.';
  end if;
  perform set_config('app.renomeando_local', 'on', true);
  update public.servidores set local = p_novo where local = p_antigo;
  get diagnostics n = row_count;
  update public.ferias_abonadas set local = p_novo where local = p_antigo;
  perform set_config('app.renomeando_local', '', true);
  return n;
end;
$fn$;
revoke execute on function public.renomear_local_servidores(text, text) from public, anon;
grant execute on function public.renomear_local_servidores(text, text) to authenticated;

-- 4. Atestados (dado de saúde: acesso só do próprio servidor e dos administradores)
create table if not exists public.atestados (
  id bigint generated always as identity primary key,
  servidor_id bigint not null references public.servidores(id) on delete cascade,
  data_inicio date not null,
  data_fim date not null,
  dias integer not null default 1,
  observacao text not null default '' check (length(observacao) <= 500),
  arquivo text not null check (length(arquivo) <= 6000000),
  arquivo_nome text not null default '' check (length(arquivo_nome) <= 200),
  arquivo_tipo text not null check (arquivo_tipo in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp')),
  status text not null default 'enviado' check (status in ('enviado', 'conferido', 'recusado')),
  motivo text not null default '' check (length(motivo) <= 500),
  enviado_por uuid default auth.uid(),
  criado_por text not null default '',
  analisado_por text,
  analisado_em timestamptz,
  created_at timestamptz not null default now(),
  constraint atestados_periodo check (data_fim >= data_inicio and data_fim - data_inicio <= 366),
  constraint atestados_arquivo_tipo check (left(arquivo, length(arquivo_tipo) + 13) = 'data:' || arquivo_tipo || ';base64,'
                                           and length(arquivo) > length(arquivo_tipo) + 13 + 100)
);
create index if not exists atestados_servidor_data on public.atestados (servidor_id, data_inicio desc);
create index if not exists atestados_status on public.atestados (status);

-- No envio pelo servidor, o banco preenche autor, data e dias; na análise, quem e quando
create or replace function public.normalizar_atestado_servidor()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_quem text;
  v_admin boolean := public.is_admin_or_above();
begin
  select u.nome into v_quem from public.users u where u.auth_uid = auth.uid() and u.active = true limit 1;
  if tg_op = 'INSERT' then
    new.dias := (new.data_fim - new.data_inicio) + 1;
    if auth.uid() is not null and not v_admin then
      new.enviado_por := auth.uid();
      new.criado_por := coalesce(v_quem, '');
      new.created_at := now();
      new.status := 'enviado';
      new.motivo := '';
      new.analisado_por := null;
      new.analisado_em := null;
    end if;
  elsif new.status is distinct from old.status then
    new.analisado_por := coalesce(v_quem, 'Sistema');
    new.analisado_em := now();
  end if;
  return new;
end;
$fn$;

drop trigger if exists normalizar_atestado_servidor on public.atestados;
create trigger normalizar_atestado_servidor
  before insert or update on public.atestados
  for each row execute function public.normalizar_atestado_servidor();

alter table public.atestados enable row level security;
drop policy if exists atestados_admin_all on public.atestados;
create policy atestados_admin_all on public.atestados
  for all to authenticated
  using (public.is_admin_or_above())
  with check (public.is_admin_or_above());
drop policy if exists atestados_servidor_le on public.atestados;
create policy atestados_servidor_le on public.atestados
  for select to authenticated
  using (servidor_id = public.meu_servidor_id());
drop policy if exists atestados_servidor_envia on public.atestados;
create policy atestados_servidor_envia on public.atestados
  for insert to authenticated
  with check (servidor_id = public.meu_servidor_id() and enviado_por = auth.uid() and status = 'enviado');
drop policy if exists atestados_servidor_cancela on public.atestados;
create policy atestados_servidor_cancela on public.atestados
  for delete to authenticated
  using (servidor_id = public.meu_servidor_id() and enviado_por = auth.uid() and status = 'enviado');

-- 5. Funções de gatilho fora de /rest/v1/rpc (continuam rodando como gatilho)
revoke execute on function public.registrar_historico_servidor() from public, anon, authenticated;
revoke execute on function public.normalizar_atestado_servidor() from public, anon, authenticated;

commit;
