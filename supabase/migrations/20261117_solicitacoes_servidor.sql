-- =====================================================================
-- Gestão de Servidores – o servidor pede as próprias férias e folgas (17/11/2026)
--
-- O que faz:
--   1. Liga cada login (public.users) ao cadastro do servidor
--      (public.servidores) pela coluna users.servidor_id. Só um login por
--      servidor. Só o Master liga um login a um servidor (gatilho
--      proteger_vinculo_servidor); desligar (deixar vazio) qualquer
--      administrador pode, inclusive quando o servidor é excluído.
--   2. Cria public.meu_servidor_id(): o servidor ligado a quem está logado.
--   3. ferias_abonadas.solicitado_por: o login que lançou o registro
--      (preenchido pelo banco; vazio nos registros anteriores).
--   4. Gatilho ferias_normalizar_pedido_servidor: no pedido feito por quem não
--      é administrador, o banco preenche autor, data, nome e local do servidor,
--      recalcula os dias e limita a observação a 500 caracteres.
--   5. Regras novas na tabela ferias_abonadas, para o servidor comum:
--      - lê só os próprios registros;
--      - cria pedidos só em nome próprio, sempre como "pendente", e só de
--        férias, folga TRE ou abonada;
--      - cancela (apaga) só os pedidos que ele mesmo fez e ainda pendentes.
--      Aprovar, rejeitar e editar continua só com os administradores.
--
-- Ordem: pode ser aplicado ANTES de publicar o index.html novo. Nada muda
-- para a versão anterior do site (ela não usa a coluna nem as regras novas).
--
-- Para desfazer:
--   drop policy ferias_servidor_le_proprias on public.ferias_abonadas;
--   drop policy ferias_servidor_solicita on public.ferias_abonadas;
--   drop policy ferias_servidor_cancela on public.ferias_abonadas;
--   drop trigger ferias_normalizar_pedido_servidor on public.ferias_abonadas;
--   drop function public.ferias_normalizar_pedido_servidor();
--   alter table public.ferias_abonadas drop column solicitado_por;
--   drop trigger proteger_vinculo_servidor on public.users;
--   drop function public.proteger_vinculo_servidor();
--   drop function public.meu_servidor_id();
--   drop index public.users_servidor_id_unico;
--   alter table public.users drop column servidor_id;
-- =====================================================================
begin;

-- 1. Vínculo login ↔ servidor
alter table public.users
  add column if not exists servidor_id bigint references public.servidores(id) on delete set null;
create unique index if not exists users_servidor_id_unico
  on public.users (servidor_id) where servidor_id is not null;

-- Só o Master liga um login a um servidor (o vínculo dá acesso aos registros dele)
create or replace function public.proteger_vinculo_servidor()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
begin
  if auth.uid() is null or public.is_master_user() then
    return new;
  end if;
  if new.servidor_id is not null
     and (tg_op = 'INSERT' or new.servidor_id is distinct from old.servidor_id) then
    raise exception 'Apenas um Master pode ligar um login a um servidor.';
  end if;
  return new;
end;
$fn$;

drop trigger if exists proteger_vinculo_servidor on public.users;
create trigger proteger_vinculo_servidor
  before insert or update on public.users
  for each row execute function public.proteger_vinculo_servidor();

-- 2. Servidor ligado a quem está logado (só perfil ativo)
create or replace function public.meu_servidor_id()
returns bigint
language sql
stable
security definer
set search_path = ''
as $fn$
  select servidor_id from public.users
   where auth_uid = auth.uid() and active = true
   limit 1;
$fn$;

revoke execute on function public.meu_servidor_id() from public, anon;
grant execute on function public.meu_servidor_id() to authenticated;

-- 3. Quem lançou o registro
alter table public.ferias_abonadas
  add column if not exists solicitado_por uuid default auth.uid();

-- 4. Pedido do servidor: o banco preenche e confere os campos
create or replace function public.ferias_normalizar_pedido_servidor()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_nome text;
  v_local text;
  v_quem text;
begin
  if auth.uid() is null or public.is_admin_or_above() then
    return new;
  end if;

  if new.tipo = 'abonada' then
    new.data_fim := new.data_inicio;
  end if;
  if new.data_inicio is null or new.data_fim is null or new.data_fim < new.data_inicio then
    raise exception 'Período inválido: a data fim não pode ser anterior à data início.';
  end if;
  if new.data_fim - new.data_inicio > 366 then
    raise exception 'Período longo demais para um pedido.';
  end if;

  select s.nome, coalesce(s.local, '') into v_nome, v_local
    from public.servidores s where s.id = new.servidor_id;
  select u.nome into v_quem
    from public.users u where u.auth_uid = auth.uid() and u.active = true limit 1;

  new.servidor_nome  := coalesce(v_nome, new.servidor_nome);
  new.local          := coalesce(v_local, '');
  new.criado_por     := coalesce(v_quem, '');
  new.solicitado_por := auth.uid();
  new.created_at     := now();
  new.observacao     := left(coalesce(new.observacao, ''), 500);
  new.dias := case new.tipo
    when 'folga_tre' then (select count(*)::int
                             from generate_series(new.data_inicio, new.data_fim, interval '1 day') d
                            where extract(isodow from d) < 6)
    when 'ferias' then (new.data_fim - new.data_inicio) + 1
    else 1
  end;
  if new.dias < 1 then
    raise exception 'O período escolhido não tem dias úteis.';
  end if;
  return new;
end;
$fn$;

drop trigger if exists ferias_normalizar_pedido_servidor on public.ferias_abonadas;
create trigger ferias_normalizar_pedido_servidor
  before insert on public.ferias_abonadas
  for each row execute function public.ferias_normalizar_pedido_servidor();

-- 5. Regras do servidor comum em ferias_abonadas (somam-se à ferias_admin_all)
drop policy if exists ferias_servidor_le_proprias on public.ferias_abonadas;
create policy ferias_servidor_le_proprias on public.ferias_abonadas
  for select to authenticated
  using (servidor_id is not null and servidor_id = public.meu_servidor_id());

drop policy if exists ferias_servidor_solicita on public.ferias_abonadas;
create policy ferias_servidor_solicita on public.ferias_abonadas
  for insert to authenticated
  with check (
    servidor_id is not null
    and servidor_id = public.meu_servidor_id()
    and solicitado_por = auth.uid()
    and status = 'pendente'
    and tipo in ('ferias', 'abonada', 'folga_tre')
    and data_fim >= data_inicio
  );

drop policy if exists ferias_servidor_cancela on public.ferias_abonadas;
create policy ferias_servidor_cancela on public.ferias_abonadas
  for delete to authenticated
  using (
    servidor_id is not null
    and servidor_id = public.meu_servidor_id()
    and solicitado_por = auth.uid()
    and status = 'pendente'
    and tipo in ('ferias', 'abonada', 'folga_tre')
  );

-- 6. Funções de gatilho fora de /rest/v1/rpc (continuam rodando como gatilho)
revoke execute on function public.proteger_vinculo_servidor() from public, anon, authenticated;
revoke execute on function public.ferias_normalizar_pedido_servidor() from public, anon, authenticated;

commit;
