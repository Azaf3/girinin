-- =========================================================
-- Chá Revelação: banco de dados no Supabase
-- Cole tudo no SQL Editor do Supabase e clique em "Run".
-- Pode rodar de novo sem problema: ele não apaga dados.
-- =========================================================

create extension if not exists unaccent with schema extensions;

-- ---------- Tabelas ----------

create table if not exists public.settings (
  id int primary key default 1 check (id = 1),
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
insert into public.settings (id) values (1) on conflict do nothing;

create table if not exists public.guests (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 80),
  email text,
  phone text,
  status text not null default 'pendente' check (status in ('pendente', 'confirmado', 'nao')),
  companions text[] not null default '{}',
  people int not null default 0,
  consent boolean not null default false,
  opt_out boolean not null default false,
  source text not null default 'site',
  responded_at timestamptz,
  created_at timestamptz not null default now()
);
-- Presente que a pessoa escolheu ao confirmar (id do item, "pix" ou "outro")
alter table public.guests add column if not exists gift_id text;
alter table public.guests add column if not exists gift_name text;
create unique index if not exists guests_email_uq on public.guests (lower(email)) where email is not null and email <> '';
create unique index if not exists guests_phone_uq on public.guests (phone) where phone is not null and phone <> '';

create table if not exists public.guesses (
  id uuid primary key default gen_random_uuid(),
  guest_id uuid references public.guests (id) on delete cascade,
  device_id text not null,
  name text not null check (char_length(name) between 1 and 80),
  choice text not null check (choice in ('menina', 'menino')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists guesses_device_uq on public.guesses (device_id);
create unique index if not exists guesses_guest_uq on public.guesses (guest_id) where guest_id is not null;

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  text text not null check (char_length(text) between 3 and 600),
  hidden boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.gifts (
  id uuid primary key default gen_random_uuid(),
  cat text not null default 'outros',
  name text not null,
  descr text not null default '',
  img text not null default '',
  url text not null default '',
  position int not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.photos (
  id uuid primary key default gen_random_uuid(),
  src text not null,
  caption text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.remind_log (
  id uuid primary key default gen_random_uuid(),
  guest_id uuid references public.guests (id) on delete cascade,
  name text not null default '',
  channel text not null check (channel in ('whatsapp', 'email')),
  created_at timestamptz not null default now()
);

-- ---------- Segurança (RLS) ----------
-- Convidados (anon): leem só o que é público e gravam pelas funções abaixo.
-- Organizadores (usuários logados): acesso total.

alter table public.settings   enable row level security;
alter table public.guests     enable row level security;
alter table public.guesses    enable row level security;
alter table public.messages   enable row level security;
alter table public.gifts      enable row level security;
alter table public.photos     enable row level security;
alter table public.remind_log enable row level security;

do $$
declare t text;
begin
  foreach t in array array['settings','guests','guesses','messages','gifts','photos','remind_log'] loop
    execute format('drop policy if exists admin_all on public.%I', t);
    execute format('create policy admin_all on public.%I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

drop policy if exists pub_read on public.settings;
create policy pub_read on public.settings for select to anon using (true);
drop policy if exists pub_read on public.gifts;
create policy pub_read on public.gifts for select to anon using (true);
drop policy if exists pub_read on public.photos;
create policy pub_read on public.photos for select to anon using (true);
drop policy if exists pub_read on public.messages;
create policy pub_read on public.messages for select to anon using (not hidden);
drop policy if exists pub_insert on public.messages;
create policy pub_insert on public.messages for insert to anon with check (hidden = false);

-- ---------- Funções auxiliares ----------

create or replace function public.norm_name(t text) returns text
language sql stable as $$
  select trim(regexp_replace(regexp_replace(lower(extensions.unaccent(coalesce(t, ''))), '[^a-z\s]', ' ', 'g'), '\s+', ' ', 'g'))
$$;

-- Mesmo nome completo, ou mesmo primeiro nome + último sobrenome.
create or replace function public.same_name(a text, b text) returns boolean
language plpgsql stable as $$
declare x text := public.norm_name(a); y text := public.norm_name(b); tx text[]; ty text[];
begin
  if x = '' or y = '' then return false; end if;
  if x = y then return true; end if;
  tx := string_to_array(x, ' '); ty := string_to_array(y, ' ');
  return array_length(tx, 1) > 1 and array_length(ty, 1) > 1
     and tx[1] = ty[1] and tx[array_length(tx, 1)] = ty[array_length(ty, 1)];
end $$;

create or replace function public.norm_phone(p text) returns text
language sql immutable as $$
  select case when length(d) > 11 and d like '55%' then substr(d, 3) else d end
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) s
$$;

-- ---------- Funções públicas (chamadas pelo site) ----------

-- Verifica se alguém já confirmou essa pessoa ou os acompanhantes (uso interno).
create or replace function public.rsvp_lookup(p_name text, p_companions text[], p_email text, p_phone text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  self_id uuid;
  covered record;
  conflicts jsonb := '[]'::jsonb;
  c text;
  g record;
begin
  select id into self_id from guests
   where (coalesce(p_email, '') <> '' and lower(email) = lower(trim(p_email)))
      or (norm_phone(p_phone) <> '' and phone = norm_phone(p_phone))
   limit 1;

  select name, responded_at into covered from guests
   where status = 'confirmado' and id is distinct from self_id
     and exists (select 1 from unnest(companions) x where same_name(x, p_name))
   limit 1;

  foreach c in array coalesce(p_companions, '{}') loop
    select name into g from guests
     where status = 'confirmado' and id is distinct from self_id
       and (same_name(name, c) or exists (select 1 from unnest(companions) x where same_name(x, c)))
     limit 1;
    if found then conflicts := conflicts || jsonb_build_object('name', c, 'by', g.name); end if;
  end loop;

  return jsonb_build_object(
    'self_id', self_id,
    'covered_by', case when covered.name is null then null else jsonb_build_object('name', covered.name, 'at', covered.responded_at) end,
    'conflicts', conflicts);
end $$;

-- Versão pública: não devolve o id do convidado.
create or replace function public.rsvp_check(p_name text, p_companions text[], p_email text, p_phone text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select rsvp_lookup(p_name, p_companions, p_email, p_phone) - 'self_id'
$$;

drop function if exists public.submit_rsvp(text, text, text, boolean, text[], boolean, boolean);
create or replace function public.submit_rsvp(
  p_name text, p_email text, p_phone text, p_attend boolean,
  p_companions text[] default '{}', p_consent boolean default false, p_force boolean default false,
  p_gift text default null, p_gift_name text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  chk jsonb;
  v_gift text := case when p_attend then nullif(trim(coalesce(p_gift, '')), '') end;
  v_gift_name text := case when p_attend and nullif(trim(coalesce(p_gift, '')), '') is not null then left(trim(coalesce(p_gift_name, '')), 120) end;
  gid uuid;
  existed boolean;
  comps text[] := case when p_attend then coalesce(p_companions, '{}') else '{}' end;
  max_people int := coalesce((select (data->>'maxPeople')::int from settings where id = 1), 4);
begin
  if char_length(trim(coalesce(p_name, ''))) < 3 then raise exception 'nome invalido'; end if;
  if trim(coalesce(p_email, '')) !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then raise exception 'email invalido'; end if;
  if length(norm_phone(p_phone)) not in (10, 11) then raise exception 'celular invalido'; end if;
  if array_length(comps, 1) is not null and array_length(comps, 1) > greatest(max_people - 1, 0) then raise exception 'acompanhantes demais'; end if;

  chk := rsvp_lookup(p_name, comps, p_email, p_phone);
  if not p_force and (chk->'covered_by' <> 'null'::jsonb or jsonb_array_length(chk->'conflicts') > 0) then
    return (chk - 'self_id') || jsonb_build_object('ok', false);
  end if;

  gid := nullif(chk->>'self_id', '')::uuid;

  -- Item único: só uma pessoa confirmada pode ficar com ele
  if v_gift is not null and coalesce((select data->'uniqueGifts' from settings where id = 1), '[]'::jsonb) ? v_gift then
    perform pg_advisory_xact_lock(hashtext('gift:' || v_gift));
    if exists (select 1 from guests where gift_id = v_gift and status = 'confirmado' and id is distinct from gid) then
      return jsonb_build_object('ok', false, 'gift_taken', true, 'covered_by', null, 'conflicts', '[]'::jsonb);
    end if;
  end if;

  existed := gid is not null;
  if existed then
    update guests set name = trim(p_name), email = lower(trim(p_email)), phone = norm_phone(p_phone),
      status = case when p_attend then 'confirmado' else 'nao' end,
      companions = comps, people = case when p_attend then 1 + coalesce(array_length(comps, 1), 0) else 0 end,
      consent = p_consent, gift_id = v_gift, gift_name = v_gift_name, responded_at = now()
    where id = gid;
  else
    insert into guests (name, email, phone, status, companions, people, consent, gift_id, gift_name, responded_at)
    values (trim(p_name), lower(trim(p_email)), norm_phone(p_phone),
      case when p_attend then 'confirmado' else 'nao' end, comps,
      case when p_attend then 1 + coalesce(array_length(comps, 1), 0) else 0 end, p_consent, v_gift, v_gift_name, now())
    returning id into gid;
  end if;
  return jsonb_build_object('ok', true, 'id', gid, 'updated', existed, 'responded_at', now());
end $$;

-- Itens únicos já escolhidos (só os ids, sem nomes de quem escolheu)
create or replace function public.gifts_taken()
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(distinct g.gift_id), '[]'::jsonb)
  from guests g, settings s
  where s.id = 1 and g.status = 'confirmado' and g.gift_id is not null
    and coalesce(s.data->'uniqueGifts', '[]'::jsonb) ? g.gift_id
$$;

create or replace function public.submit_guess(p_device text, p_guest uuid, p_name text, p_choice text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  lock_at timestamptz := ((select data->>'guessLock' from settings where id = 1) || ':00-03:00')::timestamptz;
  gname text := p_name;
  gid uuid;
begin
  if p_choice not in ('menina', 'menino') then raise exception 'palpite invalido'; end if;
  if lock_at is not null and now() > lock_at then raise exception 'palpites encerrados'; end if;
  if p_guest is not null then select name into gname from guests where id = p_guest; end if;
  if coalesce(trim(gname), '') = '' then raise exception 'nome obrigatorio'; end if;

  select id into gid from guesses where (p_guest is not null and guest_id = p_guest) or device_id = p_device limit 1;
  if gid is null then
    insert into guesses (guest_id, device_id, name, choice) values (p_guest, p_device, trim(gname), p_choice);
  else
    update guesses set choice = p_choice, name = trim(gname), guest_id = coalesce(p_guest, guest_id), updated_at = now() where id = gid;
  end if;
  return jsonb_build_object('ok', true, 'choice', p_choice);
end $$;

create or replace function public.my_guess(p_device text, p_guest uuid)
returns text
language sql stable security definer set search_path = public as $$
  select choice from guesses where (p_guest is not null and guest_id = p_guest) or device_id = p_device limit 1
$$;

-- Placar: só aparece se os organizadores liberarem ou depois da revelação.
create or replace function public.guess_counts()
returns jsonb
language sql stable security definer set search_path = public as $$
  select case when coalesce(s.data->>'showGuessResults', 'false') = 'true' or coalesce(s.data->>'revealed', '') <> ''
    then jsonb_build_object(
      'menina', (select count(*) from guesses where choice = 'menina'),
      'menino', (select count(*) from guesses where choice = 'menino'))
    else null end
  from settings s where s.id = 1
$$;

revoke all on function public.rsvp_lookup(text, text[], text, text) from public, anon, authenticated;
revoke all on function public.rsvp_check(text, text[], text, text) from public;
revoke all on function public.submit_rsvp(text, text, text, boolean, text[], boolean, boolean, text, text) from public;
revoke all on function public.gifts_taken() from public;
revoke all on function public.submit_guess(text, uuid, text, text) from public;
revoke all on function public.my_guess(text, uuid) from public;
revoke all on function public.guess_counts() from public;
grant execute on function public.rsvp_check(text, text[], text, text) to anon, authenticated;
grant execute on function public.submit_rsvp(text, text, text, boolean, text[], boolean, boolean, text, text) to anon, authenticated;
grant execute on function public.gifts_taken() to anon, authenticated;
grant execute on function public.submit_guess(text, uuid, text, text) to anon, authenticated;
grant execute on function public.my_guess(text, uuid) to anon, authenticated;
grant execute on function public.guess_counts() to anon, authenticated;

-- Permissões de tabela (o Supabase já costuma dar, aqui fica explícito)
grant usage on schema public to anon, authenticated;
grant select on public.settings, public.gifts, public.photos, public.messages to anon;
grant insert on public.messages to anon;
grant select, insert, update, delete on all tables in schema public to authenticated;


-- Itens únicos da lista padrão (o painel passa a controlar depois)
update public.settings set data = data || jsonb_build_object('uniqueGifts', '["00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002", "00000000-0000-4000-8000-000000000003", "00000000-0000-4000-8000-000000000004", "00000000-0000-4000-8000-000000000005", "00000000-0000-4000-8000-000000000006", "00000000-0000-4000-8000-000000000007", "00000000-0000-4000-8000-000000000011", "00000000-0000-4000-8000-000000000013", "00000000-0000-4000-8000-000000000014", "00000000-0000-4000-8000-000000000016", "00000000-0000-4000-8000-000000000017", "00000000-0000-4000-8000-000000000023", "00000000-0000-4000-8000-000000000024", "00000000-0000-4000-8000-000000000043", "00000000-0000-4000-8000-000000000044"]'::jsonb)
 where id = 1 and not (data ? 'uniqueGifts');

-- Atualiza o cache da API para enxergar as funções novas
notify pgrst, 'reload schema';
