# Chá Revelação

Site do chá revelação: contagem regressiva, confirmação de presença com acompanhantes, palpite menina ou menino, lista de presentes, Pix, mensagens e galeria.

- `index.html`: o site inteiro (HTML, CSS e JS num arquivo só).
- `supabase.sql`: script do banco de dados. Rode no SQL Editor do Supabase.

Os dados ficam no Supabase. O endereço do projeto e a chave `anon` estão no topo do script em `index.html`; essa chave é pública, e o que cada visitante pode ler ou gravar é definido pelas regras do `supabase.sql`. Com os dois campos vazios, o site volta a salvar só no navegador (bom para testes).

O painel dos organizadores fica no link "Área dos organizadores", no rodapé do site. O login é o usuário criado em Authentication > Users no Supabase.

Publicado via GitHub Pages (Settings > Pages > branch `main`, pasta raiz) em https://quemtanoforninho.com.br. O arquivo `CNAME` guarda esse domínio.
