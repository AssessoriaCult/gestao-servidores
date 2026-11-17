-- =====================================================================
-- Gestão de Servidores – novo tipo "Folga TRE" em férias e abonadas (17/11/2026)
--
-- A tabela ferias_abonadas só aceitava os tipos ferias, abonada e falta.
-- Este script acrescenta folga_tre (folga eleitoral), lançada como período
-- (data_inicio e data_fim) num registro só.
--
-- Ordem: pode ser aplicado ANTES de publicar o index.html novo. A versão
-- anterior do site nunca grava folga_tre, então nada muda para ela; já o
-- site novo precisa desta migração para conseguir salvar o tipo novo.
--
-- Para desfazer: primeiro trocar ou apagar os registros com tipo folga_tre
-- (senão a restrição antiga não volta) e depois:
--   alter table public.ferias_abonadas drop constraint ferias_abonadas_tipo_check;
--   alter table public.ferias_abonadas add constraint ferias_abonadas_tipo_check
--     check (tipo = any (array['ferias'::text, 'abonada'::text, 'falta'::text]));
-- =====================================================================
begin;

alter table public.ferias_abonadas drop constraint ferias_abonadas_tipo_check;
alter table public.ferias_abonadas add constraint ferias_abonadas_tipo_check
  check (tipo = any (array['ferias'::text, 'abonada'::text, 'falta'::text, 'folga_tre'::text]));

commit;
