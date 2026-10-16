-- =====================================================================
-- Gestão de Servidores – endurecimento de segurança (16/10/2026)
--
-- APLICAR SOMENTE DEPOIS de publicar o index.html v3.1.
-- A versão anterior do site não funciona com o RLS ligado
-- (lia locais antes do login, gravava a tabela inteira, etc.).
--
-- O que este script faz:
--   1. Garante o vínculo perfil (public.users) ↔ conta de acesso (auth.users)
--   2. Contas criadas por autocadastro nascem INATIVAS: só entra quem um
--      administrador cadastrou ou aprovou
--   3. Cria funções para o próprio usuário registrar o aceite LGPD e
--      vincular o perfil (sem precisar ser admin)
--   4. Impede que um admin crie, altere ou remova perfis Master
--   5. Cria a política da tabela de férias (hoje não há nenhuma)
--   6. Solicitações de acesso anônimas só entram como "pending" e com
--      tamanho limitado
--   7. LIGA o RLS nas 7 tabelas. Hoje ele está DESLIGADO: qualquer pessoa
--      com a chave pública (que está no site) lê e altera todos os dados.
--
-- Tudo roda numa transação: se algo falhar, nada é aplicado.
-- Para desfazer só o item 7 (emergência):
--   alter table public.<tabela> disable row level security;
-- =====================================================================
begin;

-- 1. Vínculo perfil ↔ conta de acesso ---------------------------------
update public.users u
   set auth_uid = a.id
  from auth.users a
 where u.auth_uid is null
   and lower(u.email) = lower(a.email);

-- 2. Novas contas: perfil inativo, a menos que o admin já tenha cadastrado
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  insert into public.users (email, nome, role, active, lgpd_consent, auth_uid)
  values (
    lower(new.email),
    coalesce(new.raw_user_meta_data->>'nome', split_part(new.email, '@', 1)),
    'user', false, false, new.id
  )
  on conflict (email) do update
     set auth_uid = excluded.auth_uid
   where public.users.auth_uid is null;
  return new;
end;
$fn$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- 3. Funções chamadas pelo próprio usuário logado ---------------------
create or replace function public.registrar_consentimento_lgpd()
returns void
language sql
security definer
set search_path = ''
as $fn$
  update public.users set lgpd_consent = true where auth_uid = auth.uid();
$fn$;

create or replace function public.vincular_meu_perfil()
returns void
language sql
security definer
set search_path = ''
as $fn$
  update public.users
     set auth_uid = auth.uid()
   where auth_uid is null
     and auth.uid() is not null
     and lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''));
$fn$;

revoke execute on function public.registrar_consentimento_lgpd() from public, anon;
revoke execute on function public.vincular_meu_perfil() from public, anon;
grant execute on function public.registrar_consentimento_lgpd() to authenticated;
grant execute on function public.vincular_meu_perfil() to authenticated;

-- 4. Só Master mexe em perfil Master ----------------------------------
create or replace function public.proteger_perfis_master()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  -- Sem usuário logado (SQL Editor, gatilho do Auth) ou quem age é Master: liberado
  if auth.uid() is null or public.is_master_user() then
    return coalesce(new, old);
  end if;

  if (tg_op = 'INSERT' and new.role = 'master')
     or (tg_op = 'DELETE' and old.role = 'master')
     or (tg_op = 'UPDATE' and (
           (new.role = 'master' and old.role is distinct from 'master')
        or (old.role = 'master' and (new.role, new.active, new.email, new.nome)
                                     is distinct from (old.role, old.active, old.email, old.nome))
     ))
  then
    raise exception 'Apenas um Master pode criar, alterar ou remover perfis Master.';
  end if;

  return coalesce(new, old);
end;
$fn$;

revoke execute on function public.proteger_perfis_master() from public, anon, authenticated;

drop trigger if exists proteger_perfis_master on public.users;
create trigger proteger_perfis_master
  before insert or update or delete on public.users
  for each row execute function public.proteger_perfis_master();

-- 5. Férias e abonadas: só administradores ----------------------------
drop policy if exists ferias_admin_all on public.ferias_abonadas;
create policy ferias_admin_all on public.ferias_abonadas
  for all to authenticated
  using (public.is_admin_or_above())
  with check (public.is_admin_or_above());

-- 6. Solicitação de acesso anônima: só "pending" e com tamanho limitado
drop policy if exists requests_public_insert on public.access_requests;
create policy requests_public_insert on public.access_requests
  for insert to anon, authenticated
  with check (
    status = 'pending'
    and length(nome) between 1 and 120
    and length(email) between 3 and 160
    and length(coalesce(motivo, '')) <= 300
    and length(coalesce(justificativa, '')) <= 300
  );

-- Funções de gatilho com search_path fixo (aviso do Security Advisor)
alter function public.set_updated_at() set search_path = '';

-- 7. Liga o RLS --------------------------------------------------------
alter table public.users           enable row level security;
alter table public.servidores      enable row level security;
alter table public.access_requests enable row level security;
alter table public.audit_log       enable row level security;
alter table public.locais          enable row level security;
alter table public.system_config   enable row level security;
alter table public.ferias_abonadas enable row level security;

commit;
