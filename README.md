# gestao-servidores
Gestão de Servidores de Secretaria Pública – Secretaria Municipal de Cultura de Araçatuba.

Aplicação de página única (`index.html`) publicada pelo GitHub Pages, com dados no Supabase.

## Segurança (leia antes de publicar)

- A chave que aparece no `index.html` é a chave **pública** (anon) do Supabase. Quem protege os
  dados é o **RLS (Row Level Security)** das tabelas. Sem RLS ligado, qualquer pessoa com essa
  chave lê e altera todos os dados.
- A migração `supabase/migrations/20261016_seguranca_rls.sql` liga o RLS e cria as regras de
  acesso. **Ordem obrigatória:** primeiro publicar o `index.html` v3.1, depois rodar a migração
  no SQL Editor do Supabase (a versão anterior do site não funciona com o RLS ligado).
- Perfis: **Usuário** (consulta), **Administrador** (gerencia servidores, locais, férias e
  usuários) e **Master** (também importa/exporta dados e gerencia outros Masters).
- Quem não tem perfil ativo na tabela `users` não entra, mesmo tendo conta de acesso.
- Senhas: o administrador não define nem vê a senha alheia; o sistema envia um link de
  redefinição por e-mail. Na tela de login há "Esqueci minha senha".
- Ao sair, a cópia temporária dos dados guardada no navegador é apagada.

## Configurações do Supabase a conferir no painel

- **Authentication → URL Configuration:** incluir
  `https://assessoriacult.github.io/gestao-servidores/` em *Redirect URLs* (links de senha).
- **Authentication → Providers → Email:** manter "Confirm email" ligado e tamanho mínimo de
  senha 8.
- **Authentication → Attack Protection:** ligar "Leaked password protection" (se o plano permitir).

## Testes

Os fluxos foram testados com um Supabase simulado (dados fictícios), com o RLS desligado (como
está hoje) e ligado (como fica após a migração). A migração foi validada no banco real dentro
de uma transação desfeita ao final.
