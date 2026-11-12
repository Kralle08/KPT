-- ============================================================
-- KPT – Kulinarisches Projekt TEam · Datenbank für die Club-App
-- Im Supabase "SQL Editor" komplett einfügen und einmal ausführen.
-- ============================================================

-- ---------- Tabellen ----------------------------------------

create table public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  name       text not null check (char_length(btrim(name)) between 2 and 40),
  is_admin   boolean not null default false,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

-- Club-Einstellungen (genau eine Zeile). Einladungscode hier ändern:
create table public.club (
  id          int primary key default 1 check (id = 1),
  invite_code text not null
);
insert into public.club (id, invite_code) values (1, 'KOCHLOEFFEL');

-- Ein Eintrag pro Freitag, an dem gekocht wird (1 oder 2 Köche)
create table public.meals (
  day         date primary key check (extract(isodow from day) = 5),
  cook1       uuid not null references public.profiles (id),
  cook2       uuid references public.profiles (id),
  title       text not null default '' check (char_length(title) <= 120),
  description text not null default '' check (char_length(description) <= 2000),
  recipe      text not null default '' check (char_length(recipe) <= 20000),
  cost        numeric(8,2) check (cost is null or cost between 0 and 5000),  -- Einkaufskosten gesamt in Euro
  created_at  timestamptz not null default now(),
  check (cook2 is null or cook2 <> cook1)
);

-- An- und Abmeldungen, mit bis zu 5 Gästen
create table public.rsvps (
  day     date not null check (extract(isodow from day) = 5),
  user_id uuid not null references public.profiles (id) on delete cascade,
  coming  boolean not null,
  guests  smallint not null default 0 check (guests between 0 and 5),
  primary key (day, user_id),
  check (coming or guests = 0)
);

-- Bewertungen mit 1 bis 5 Kochlöffeln
create table public.ratings (
  day        date not null references public.meals (day) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  spoons     smallint not null check (spoons between 1 and 5),
  comment    text not null default '' check (char_length(comment) <= 500),
  created_at timestamptz not null default now(),
  primary key (day, user_id)
);

-- Fotos zu einem Essen (die Bilddatei liegt im Speicher "fotos")
create table public.photos (
  id         uuid primary key default gen_random_uuid(),
  day        date not null references public.meals (day) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  path       text not null,
  created_at timestamptz not null default now()
);

-- Chat
create table public.messages (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  body       text not null check (char_length(btrim(body)) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index messages_created_idx on public.messages (created_at desc);

-- Clubkasse: Zahlungen zwischen Mitgliedern ("von" hat "an" Geld gegeben)
create table public.payments (
  id         bigint generated always as identity primary key,
  from_user  uuid not null references public.profiles (id),
  to_user    uuid not null references public.profiles (id),
  amount     numeric(8,2) not null check (amount > 0 and amount <= 5000),
  created_by uuid not null default auth.uid() references public.profiles (id),
  created_at timestamptz not null default now(),
  check (from_user <> to_user)
);

-- Geräte, die Push-Erinnerungen bekommen (nur über die Funktionen unten erreichbar)
create table public.push_subscriptions (
  endpoint   text primary key,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);

-- ---------- Hilfsfunktionen ---------------------------------

create function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active);
$$;

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active and is_admin);
$$;

create function public.berlin_today() returns date
language sql stable as $$
  select (now() at time zone 'Europe/Berlin')::date;
$$;

-- An-/Abmeldung ist bis Mittwoch 23:59 Uhr (deutsche Zeit) offen
create function public.rsvp_open(d date) returns boolean
language sql stable as $$
  select (now() at time zone 'Europe/Berlin') < (d - 1)::timestamp;
$$;

-- ---------- Aktionen ----------------------------------------

-- Dem Club beitreten (nach der Registrierung, mit Einladungscode)
create function public.join_club(code text, member_name text) returns public.profiles
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  p  profiles;
begin
  if me is null then raise exception 'Bitte zuerst anmelden.'; end if;
  select * into p from profiles where id = me;
  if found then return p; end if;
  if not exists (select 1 from club where upper(btrim(invite_code)) = upper(btrim(code))) then
    raise exception 'Der Einladungscode stimmt nicht.';
  end if;
  lock table profiles in share row exclusive mode;
  insert into profiles (id, name, is_admin)
  values (me, btrim(member_name), not exists (select 1 from profiles))
  returning * into p;
  return p;
end $$;

-- Sich für einen Freitag als Koch eintragen
create function public.claim_friday(d date) returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  m  meals;
begin
  if not is_member() then raise exception 'Nur für Mitglieder.'; end if;
  if extract(isodow from d) <> 5 then raise exception 'Gekocht wird freitags.'; end if;
  if d < berlin_today() then raise exception 'Dieser Freitag ist schon vorbei.'; end if;

  insert into meals (day, cook1) values (d, me) on conflict (day) do nothing;
  select * into m from meals where day = d for update;
  if m.cook1 = me or m.cook2 = me then
    null;
  elsif m.cook2 is null then
    update meals set cook2 = me where day = d;
  else
    raise exception 'An diesem Freitag kochen schon zwei Personen.';
  end if;

  -- Wer kocht, isst auch mit
  insert into rsvps (day, user_id, coming) values (d, me, true)
  on conflict (day, user_id) do update set coming = true;
end $$;

-- Sich als Koch wieder austragen (Admins können auch andere austragen)
create function public.release_friday(d date, who uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare
  target uuid := coalesce(who, auth.uid());
  m      meals;
begin
  if not is_member() then raise exception 'Nur für Mitglieder.'; end if;
  if target <> auth.uid() and not is_admin() then raise exception 'Nur für Admins.'; end if;
  if d < berlin_today() then raise exception 'Vergangene Freitage lassen sich nicht ändern.'; end if;

  select * into m from meals where day = d for update;
  if not found then return; end if;
  if m.cook1 = target then
    if m.cook2 is null then
      delete from meals where day = d;
    else
      update meals set cook1 = m.cook2, cook2 = null where day = d;
    end if;
  elsif m.cook2 = target then
    update meals set cook2 = null where day = d;
  end if;
end $$;

-- Admin: Einladungscode lesen / ändern
create function public.get_invite_code() returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Nur für Admins.'; end if;
  return (select invite_code from club where id = 1);
end $$;

create function public.set_invite_code(code text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Nur für Admins.'; end if;
  if char_length(btrim(code)) < 4 then raise exception 'Der Code braucht mindestens 4 Zeichen.'; end if;
  update club set invite_code = btrim(code) where id = 1;
end $$;

-- Admin: Mitglied pausieren/aktivieren, Admin-Recht geben/nehmen
create function public.admin_set_member(target uuid, set_active boolean, set_admin boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Nur für Admins.'; end if;
  if target = auth.uid() and not (set_active and set_admin) then
    raise exception 'Du kannst dir das Admin-Recht nicht selbst nehmen.';
  end if;
  update profiles set active = set_active, is_admin = set_admin where id = target;
end $$;

-- Admin: neues Passwort für ein Mitglied setzen (falls vergessen)
create function public.admin_set_password(target uuid, new_password text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not is_admin() then raise exception 'Nur für Admins.'; end if;
  if char_length(new_password) < 8 then raise exception 'Das Passwort braucht mindestens 8 Zeichen.'; end if;
  if not exists (select 1 from profiles where id = target) then raise exception 'Mitglied nicht gefunden.'; end if;
  update auth.users
     set encrypted_password = crypt(new_password, gen_salt('bf', 10)), updated_at = now()
   where id = target;
end $$;

-- Push-Erinnerungen für dieses Gerät ein-/ausschalten
create function public.save_push(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_member() then raise exception 'Nur für Mitglieder.'; end if;
  insert into push_subscriptions (endpoint, user_id, p256dh, auth)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth)
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
end $$;

create function public.drop_push(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;

revoke execute on function public.save_push(text, text, text), public.drop_push(text) from public, anon;
grant execute on function public.save_push(text, text, text), public.drop_push(text) to authenticated;

revoke execute on function public.join_club(text, text), public.claim_friday(date),
  public.release_friday(date, uuid), public.get_invite_code(), public.set_invite_code(text),
  public.admin_set_member(uuid, boolean, boolean), public.admin_set_password(uuid, text)
  from public, anon;
grant execute on function public.join_club(text, text), public.claim_friday(date),
  public.release_friday(date, uuid), public.get_invite_code(), public.set_invite_code(text),
  public.admin_set_member(uuid, boolean, boolean), public.admin_set_password(uuid, text)
  to authenticated;

-- ---------- Zugriffsregeln (Row Level Security) -------------

alter table public.profiles enable row level security;
alter table public.club     enable row level security;
alter table public.meals    enable row level security;
alter table public.rsvps    enable row level security;
alter table public.ratings  enable row level security;
alter table public.photos   enable row level security;
alter table public.messages enable row level security;
alter table public.payments enable row level security;
alter table public.push_subscriptions enable row level security;

-- Nur angemeldete Nutzer, nie anonym
revoke all on public.profiles, public.club, public.meals, public.rsvps,
  public.ratings, public.photos, public.messages, public.payments, public.push_subscriptions from anon;
revoke all on public.club, public.push_subscriptions from authenticated;

-- Profile: Mitglieder sehen alle, jeder ändert nur den eigenen Namen
revoke insert, update, delete on public.profiles from authenticated;
grant update (name) on public.profiles to authenticated;
create policy profiles_select on public.profiles for select to authenticated
  using (is_member() or id = auth.uid());
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Essen: Mitglieder sehen alles, Köche pflegen Gericht, Beschreibung, Rezept, Kosten
revoke insert, update, delete on public.meals from authenticated;
grant update (title, description, recipe, cost) on public.meals to authenticated;
create policy meals_select on public.meals for select to authenticated
  using (is_member());
create policy meals_update on public.meals for update to authenticated
  using (is_member() and auth.uid() in (cook1, cook2))
  with check (is_member() and auth.uid() in (cook1, cook2));

-- An-/Abmeldung: nur für sich selbst und nur bis Mittwoch 23:59 Uhr
create policy rsvps_select on public.rsvps for select to authenticated
  using (is_member());
create policy rsvps_insert on public.rsvps for insert to authenticated
  with check (user_id = auth.uid() and is_member() and rsvp_open(day));
create policy rsvps_update on public.rsvps for update to authenticated
  using (user_id = auth.uid() and is_member() and rsvp_open(day))
  with check (user_id = auth.uid() and is_member() and rsvp_open(day));

-- Bewertung: ab dem Tag des Essens, nur wer angemeldet war, nicht das eigene Essen
create function public.may_rate(d date) returns boolean
language sql stable security definer set search_path = public as $$
  select is_member()
     and d <= berlin_today()
     and exists (select 1 from rsvps r where r.day = d and r.user_id = auth.uid() and r.coming)
     and exists (select 1 from meals m where m.day = d
                 and m.cook1 <> auth.uid()
                 and (m.cook2 is null or m.cook2 <> auth.uid()));
$$;
create policy ratings_select on public.ratings for select to authenticated
  using (is_member());
create policy ratings_insert on public.ratings for insert to authenticated
  with check (user_id = auth.uid() and may_rate(day));
create policy ratings_update on public.ratings for update to authenticated
  using (user_id = auth.uid() and may_rate(day))
  with check (user_id = auth.uid() and may_rate(day));

-- Fotos: alle Mitglieder dürfen teilen, löschen nur eigene (oder Admin)
revoke update on public.photos from authenticated;
create policy photos_select on public.photos for select to authenticated
  using (is_member());
create policy photos_insert on public.photos for insert to authenticated
  with check (user_id = auth.uid() and is_member());
create policy photos_delete on public.photos for delete to authenticated
  using (is_member() and (user_id = auth.uid() or is_admin()));

-- Chat: lesen und schreiben für Mitglieder, löschen nur eigene (oder Admin)
revoke update on public.messages from authenticated;
create policy messages_select on public.messages for select to authenticated
  using (is_member());
create policy messages_insert on public.messages for insert to authenticated
  with check (user_id = auth.uid() and is_member());
create policy messages_delete on public.messages for delete to authenticated
  using (is_member() and (user_id = auth.uid() or is_admin()));

-- Kasse: alle sehen alles; eintragen darf, wer zahlt oder das Geld bekommt
revoke update on public.payments from authenticated;
create policy payments_select on public.payments for select to authenticated
  using (is_member());
create policy payments_insert on public.payments for insert to authenticated
  with check (is_member() and created_by = auth.uid() and auth.uid() in (from_user, to_user));
create policy payments_delete on public.payments for delete to authenticated
  using (is_member() and (created_by = auth.uid() or is_admin()));

-- ---------- Bildspeicher ------------------------------------

insert into storage.buckets (id, name, public)
values ('fotos', 'fotos', true)
on conflict (id) do nothing;

create policy fotos_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'fotos' and public.is_member()
              and (storage.foldername(name))[1] = auth.uid()::text);
create policy fotos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'fotos' and public.is_member()
         and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- ---------- Live-Aktualisierung -----------------------------

alter publication supabase_realtime add table
  public.messages, public.meals, public.rsvps, public.ratings, public.photos, public.profiles, public.payments;
