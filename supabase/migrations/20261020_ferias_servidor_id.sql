-- =====================================================================
-- Gestão de Servidores – férias vinculadas pelo id do servidor (20/10/2026)
--
-- APLICAR SOMENTE DEPOIS de publicar o index.html que grava servidor_id.
-- O site novo funciona com ou sem esta coluna (sem ela, vincula pelo nome);
-- aplicando depois, o preenchimento abaixo alcança também os registros
-- feitos até o momento da aplicação.
--
-- Problema: ferias_abonadas aponta para o servidor só pelo nome
-- (servidor_nome). Com dois servidores de mesmo nome, ou com um nome
-- corrigido fora do sistema, o vínculo se perde.
--
-- O que este script faz:
--   1. Cria ferias_abonadas.servidor_id → servidores(id). Se o servidor for
--      excluído, o registro de férias continua existindo, sem vínculo
--      (on delete set null), e segue mostrando o nome gravado.
--   2. Preenche o vínculo dos registros existentes pelo nome, só quando o
--      nome corresponde a UM único servidor (sem diferenciar maiúsculas
--      nem espaços sobrando). Nome repetido ou não encontrado fica sem
--      vínculo: o site mostra o nome gravado e pede para escolher o
--      servidor ao editar.
--   3. Mantém servidor_nome como cópia do nome, para histórico.
--   4. Confere que o RLS e a política ferias_admin_all continuam valendo
--      (a coluna nova não muda quem pode ler ou gravar).
--
-- Tudo roda numa transação: se algo falhar, nada é aplicado.
-- Para desfazer (o site continua funcionando, vinculando pelo nome):
--   alter table public.ferias_abonadas drop column servidor_id;
-- =====================================================================
begin;

-- 1. Coluna de vínculo -------------------------------------------------
alter table public.ferias_abonadas
  add column if not exists servidor_id bigint
  references public.servidores(id) on delete set null;

create index if not exists ferias_abonadas_servidor_id_idx
  on public.ferias_abonadas (servidor_id);

comment on column public.ferias_abonadas.servidor_id is
  'Servidor do registro. Fica vazio se o servidor for excluído.';
comment on column public.ferias_abonadas.servidor_nome is
  'Cópia do nome do servidor, para histórico. O vínculo é servidor_id.';

-- 2. Preenche pelo nome, só quando ele identifica um único servidor ----
with servidor_unico as (
  select min(id) as id,
         lower(regexp_replace(btrim(nome), '\s+', ' ', 'g')) as chave
    from public.servidores
   group by 2
  having count(*) = 1
)
update public.ferias_abonadas f
   set servidor_id = u.id
  from servidor_unico u
 where f.servidor_id is null
   and lower(regexp_replace(btrim(f.servidor_nome), '\s+', ' ', 'g')) = u.chave;

-- 4. Conferências -------------------------------------------------------
do $chk$
declare
  sem_vinculo integer;
begin
  if not (select relrowsecurity from pg_class where oid = 'public.ferias_abonadas'::regclass) then
    raise exception 'RLS desligado em ferias_abonadas: migração cancelada.';
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'ferias_abonadas'
                    and policyname = 'ferias_admin_all') then
    raise exception 'Política ferias_admin_all não encontrada: migração cancelada.';
  end if;

  select count(*) into sem_vinculo from public.ferias_abonadas where servidor_id is null;
  if sem_vinculo > 0 then
    raise notice '% registro(s) de férias ficaram sem vínculo (nome não encontrado ou repetido). Continuam aparecendo pelo nome; ao editar, escolha o servidor.', sem_vinculo;
  end if;
end
$chk$;

-- Avisa a API para enxergar a coluna nova na hora
notify pgrst, 'reload schema';

commit;
