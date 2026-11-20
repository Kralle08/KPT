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
  cost        numeric(8,2) check (cost is null or cost between 0 and 5000),    -- Einkauf von Koch 1 in Euro
  cost2       numeric(8,2) check (cost2 is null or cost2 between 0 and 5000),  -- Einkauf von Koch 2 in Euro
  created_at  timestamptz not null default now(),
  check (cook2 is null or cook2 <> cook1)
);

-- An- und Abmeldungen, mit bis zu 5 Gästen. "late" = nach Mittwoch geändert
create table public.rsvps (
  day     date not null check (extract(isodow from day) = 5),
  user_id uuid not null references public.profiles (id) on delete cascade,
  coming  boolean not null,
  guests  smallint not null default 0 check (guests between 0 and 5),
  late    boolean not null default false,
  primary key (day, user_id),
  check (coming or guests = 0)
);

-- Bewertungen mit 1 bis 5 Kochlöffeln
create table public.ratings (
  day        date not null references public.meals (day) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  spoons     smallint not null check (spoons between 1 and 5),
  comment    text not null default '' check (char_length(comment) <= 500),
  gold        boolean not null default false,      -- goldener Löffel: zählt im Ranking wie 10 Löffel
  gold_reason text not null default '' check (char_length(gold_reason) <= 1000),
  created_at timestamptz not null default now(),
  primary key (day, user_id),
  constraint ratings_gold_check check (not gold or (spoons = 5 and char_length(btrim(gold_reason)) >= 20))
);
-- Jedes Mitglied hat einen goldenen Löffel pro Kalenderjahr
create unique index ratings_gold_per_year on public.ratings (user_id, (extract(year from day))) where gold;

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

-- Frist: bis Mittwoch 23:59 Uhr (deutsche Zeit) soll jeder geantwortet haben
create function public.rsvp_soft_open(d date) returns boolean
language sql stable as $$
  select (now() at time zone 'Europe/Berlin') < (d - 1)::timestamp;
$$;

-- Nachmelden (nur Zusagen) geht noch bis Donnerstag 18 Uhr
create function public.rsvp_open(d date) returns boolean
language sql stable as $$
  select (now() at time zone 'Europe/Berlin') < (d - 1)::timestamp + interval '18 hours';
$$;

-- Die Zahl der Gäste lässt sich bis Freitag 12 Uhr ändern
create function public.rsvp_guests_open(d date) returns boolean
language sql stable as $$
  select (now() at time zone 'Europe/Berlin') < d::timestamp + interval '12 hours';
$$;

-- Bewerten geht ab Freitag 12:30 Uhr
create function public.rate_open(d date) returns boolean
language sql stable as $$
  select (now() at time zone 'Europe/Berlin') >= d::timestamp + interval '12 hours 30 minutes';
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

  -- Wer kocht, isst auch mit (gilt auch nach Anmeldeschluss)
  perform set_config('kpt.koch', '1', true);
  insert into rsvps (day, user_id, coming) values (d, me, true)
  on conflict (day, user_id) do update set coming = true;
  perform set_config('kpt.koch', '0', true);
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
      update meals set cook1 = m.cook2, cook2 = null, cost = m.cost2, cost2 = null where day = d;
    end if;
  elsif m.cook2 = target then
    update meals set cook2 = null, cost2 = null where day = d;
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

-- Admin: ein früheres Essen nachtragen (Koch, Gericht, wer mitgegessen hat)
create function public.admin_add_past_meal(d date, c1 uuid, c2 uuid, t text, attendees uuid[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Nur für Admins.'; end if;
  if extract(isodow from d) <> 5 then raise exception 'Gekocht wird freitags.'; end if;
  if d >= berlin_today() then raise exception 'Nachtragen geht nur für vergangene Freitage.'; end if;
  if exists (select 1 from meals where day = d) then raise exception 'Für diesen Freitag gibt es schon ein Essen.'; end if;
  if c1 is null then raise exception 'Bitte einen Koch auswählen.'; end if;
  insert into meals (day, cook1, cook2, title) values (d, c1, nullif(c2, c1), coalesce(btrim(t), ''));
  perform set_config('kpt.koch', '2', true);
  insert into rsvps (day, user_id, coming)
  select d, u, true
    from (select unnest(coalesce(attendees, '{}') || array[c1, c2]) as u) x
   where u is not null and exists (select 1 from profiles where id = u)
   group by u
  on conflict (day, user_id) do update set coming = true;
  perform set_config('kpt.koch', '0', true);
end $$;

-- Admin: ein vergangenes Essen wieder löschen (mit Anmeldungen, Bewertungen und Fotos)
create function public.admin_delete_meal(d date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Nur für Admins.'; end if;
  if d >= berlin_today() then raise exception 'Nur vergangene Essen lassen sich löschen.'; end if;
  delete from rsvps where day = d;
  delete from meals where day = d;
end $$;

-- Admin: bei einem Essen von Hand eintragen, wer mitisst oder mitgegessen hat (auch nach Anmeldeschluss)
create function public.admin_set_attendance(d date, who uuid, is_coming boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Nur für Admins.'; end if;
  if not exists (select 1 from meals where day = d) then raise exception 'Für diesen Freitag gibt es kein Essen.'; end if;
  if not exists (select 1 from profiles where id = who) then raise exception 'Mitglied nicht gefunden.'; end if;
  if not is_coming and exists (select 1 from meals where day = d and who in (cook1, cook2)) then
    raise exception 'Wer kocht, isst immer mit.';
  end if;
  perform set_config('kpt.koch', '1', true);
  insert into rsvps (day, user_id, coming, guests) values (d, who, is_coming, 0)
  on conflict (day, user_id) do update
    set coming = excluded.coming,
        guests = case when excluded.coming then rsvps.guests else 0 end;
  perform set_config('kpt.koch', '0', true);
end $$;

revoke execute on function public.admin_set_attendance(date, uuid, boolean) from public, anon;
grant execute on function public.admin_set_attendance(date, uuid, boolean) to authenticated;

revoke execute on function public.admin_add_past_meal(date, uuid, uuid, text, uuid[]), public.admin_delete_meal(date) from public, anon;
grant execute on function public.admin_add_past_meal(date, uuid, uuid, text, uuid[]), public.admin_delete_meal(date) to authenticated;

revoke execute on function public.join_club(text, text), public.claim_friday(date),
  public.release_friday(date, uuid), public.get_invite_code(), public.set_invite_code(text),
  public.admin_set_member(uuid, boolean, boolean), public.admin_set_password(uuid, text)
  from public, anon;
grant execute on function public.join_club(text, text), public.claim_friday(date),
  public.release_friday(date, uuid), public.get_invite_code(), public.set_invite_code(text),
  public.admin_set_member(uuid, boolean, boolean), public.admin_set_password(uuid, text)
  to authenticated;

-- ---------- Nachmeldungen -----------------------------------

-- Bis Mittwoch 23:59 Uhr: frei an- und abmelden.
-- Bis Donnerstag 18 Uhr: nur noch nachmelden (zusagen), nicht mehr absagen.
-- Bis Freitag 12 Uhr: nur noch die Zahl der Gäste ändern.
-- "late" merkt sich Zusagen und zusätzliche Gäste nach Mittwoch.
create function public.rsvps_before() returns trigger
language plpgsql as $$
begin
  if coalesce(current_setting('kpt.koch', true), '') in ('1', '2') then   -- 1: "Ich koche", 2: Nachtrag durch Admin
    new.late := current_setting('kpt.koch', true) = '1' and not public.rsvp_soft_open(new.day);
    return new;
  end if;
  if tg_op = 'INSERT' then
    if not public.rsvp_open(new.day) then
      raise exception 'Die Anmeldung ist geschlossen.';
    end if;
    new.late := not public.rsvp_soft_open(new.day);
    return new;
  end if;
  if new.coming = old.coming and new.guests = old.guests then
    new.late := old.late;
    return new;
  end if;
  if public.rsvp_soft_open(new.day) then                              -- bis Mittwoch: alles frei
    new.late := false;
    return new;
  end if;
  if old.coming and not new.coming then
    raise exception 'Nach Mittwoch geht nur noch Nachmelden, Absagen nicht mehr.';
  end if;
  if new.coming <> old.coming and not public.rsvp_open(new.day) then  -- ab Donnerstag 18 Uhr: nur noch Gäste
    raise exception 'Die Anmeldung ist geschlossen.';
  end if;
  new.late := old.late or new.coming <> old.coming or new.guests > old.guests;
  return new;
end $$;
create trigger rsvps_before before insert or update on public.rsvps
  for each row execute function public.rsvps_before();

-- ---------- Goldener Löffel ---------------------------------

-- Vergabe ab Essen vom 1. Januar 2027, jeweils ab Freitag 12:30 Uhr bis Donnerstag 23:59 Uhr danach
create function public.gold_open(d date) returns boolean
language sql stable as $$
  select d >= date '2027-01-01'
     and public.rate_open(d)
     and (now() at time zone 'Europe/Berlin') < (d + 7)::timestamp;
$$;

create function public.ratings_gold() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' and old.gold then
    if not new.gold or new.spoons <> 5 or new.gold_reason is distinct from old.gold_reason then
      raise exception 'Ein goldener Löffel ist endgültig und lässt sich nicht mehr ändern.';
    end if;
    return new;
  end if;
  if new.gold then
    if not public.gold_open(new.day) then
      raise exception 'Goldene Löffel gibt es für Essen ab dem 1. Januar 2027, jeweils bis zum Donnerstag nach dem Essen.';
    end if;
    if exists (select 1 from public.ratings r
               where r.user_id = new.user_id and r.gold and r.day <> new.day
                 and extract(year from r.day) = extract(year from new.day)) then
      raise exception 'Du hast deinen goldenen Löffel für % schon vergeben.', extract(year from new.day);
    end if;
  end if;
  return new;
end $$;
create trigger ratings_gold before insert or update on public.ratings
  for each row execute function public.ratings_gold();

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

-- Essen: Mitglieder sehen alles; Köche und Admins pflegen Gericht, Beschreibung, Rezept, Kosten
revoke insert, update, delete on public.meals from authenticated;
grant update (title, description, recipe, cost, cost2) on public.meals to authenticated;
create policy meals_select on public.meals for select to authenticated
  using (is_member());
create policy meals_update on public.meals for update to authenticated
  using (is_member() and (auth.uid() in (cook1, cook2) or is_admin()))
  with check (is_member() and (auth.uid() in (cook1, cook2) or is_admin()));

-- An-/Abmeldung: nur für sich selbst; die Fristen stehen bei "Nachmeldungen" weiter oben
create policy rsvps_select on public.rsvps for select to authenticated
  using (is_member());
create policy rsvps_insert on public.rsvps for insert to authenticated
  with check (user_id = auth.uid() and is_member() and rsvp_open(day));
create policy rsvps_update on public.rsvps for update to authenticated
  using (user_id = auth.uid() and is_member() and rsvp_guests_open(day))
  with check (user_id = auth.uid() and is_member() and rsvp_guests_open(day));

-- Bewertung: ab Freitag 12:30 Uhr, nur wer angemeldet war, nicht das eigene Essen
create function public.may_rate(d date) returns boolean
language sql stable security definer set search_path = public as $$
  select is_member()
     and rate_open(d)
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

-- ---------- Reaktionen auf Fotos (👍 😋 ❤️) ----------------------------
create table if not exists public.photo_reactions (
  photo_id   uuid not null references public.photos (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  emoji      text not null check (emoji in ('👍', '😋', '❤️')),
  created_at timestamptz not null default now(),
  primary key (photo_id, user_id, emoji)
);
alter table public.photo_reactions enable row level security;
revoke all on public.photo_reactions from anon;
revoke update on public.photo_reactions from authenticated;

drop policy if exists photo_reactions_select on public.photo_reactions;
create policy photo_reactions_select on public.photo_reactions for select to authenticated
  using (is_member());
drop policy if exists photo_reactions_insert on public.photo_reactions;
create policy photo_reactions_insert on public.photo_reactions for insert to authenticated
  with check (user_id = auth.uid() and is_member());
drop policy if exists photo_reactions_delete on public.photo_reactions;
create policy photo_reactions_delete on public.photo_reactions for delete to authenticated
  using (user_id = auth.uid() and is_member());

do $$ begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'photo_reactions') then
    alter publication supabase_realtime add table public.photo_reactions;
  end if;
end $$;

-- ---------- Mitteilungen --------------------------------------------
-- Jede Minute prüft die Datenbank, ob etwas zu verschicken ist (Erinnerungen,
-- neue Chatnachrichten, neue Fotos), und gibt es an die Supabase-Funktion "push".

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

-- Was jedes Mitglied bekommen möchte
alter table public.profiles add column if not exists notify_friday boolean not null default true;
alter table public.profiles add column if not exists notify_chat   boolean not null default true;
alter table public.profiles add column if not exists notify_photos boolean not null default false;
grant update (notify_friday, notify_chat, notify_photos) on public.profiles to authenticated;

-- Adresse und Passwort der Funktion "push" (wird einmal von Hand eingetragen)
create table if not exists public.push_config (
  id           int primary key default 1 check (id = 1),
  function_url text,
  secret       text
);
insert into public.push_config (id) values (1) on conflict do nothing;

-- Bis wohin Chat und Fotos schon gemeldet sind
create table if not exists public.push_state (
  id              int primary key default 1 check (id = 1),
  last_message_id bigint not null default 0,
  last_photo_at   timestamptz not null default now()
);
insert into public.push_state (id, last_message_id, last_photo_at)
select 1, coalesce((select max(id) from public.messages), 0), now()
on conflict do nothing;

-- Welche Erinnerungen schon verschickt wurden (damit nichts doppelt kommt)
create table if not exists public.push_log (
  key     text primary key,
  sent_at timestamptz not null default now()
);

alter table public.push_config enable row level security;
alter table public.push_state  enable row level security;
alter table public.push_log    enable row level security;
revoke all on public.push_config, public.push_state, public.push_log from anon, authenticated;

-- Merkt sich eine Erinnerung als verschickt; liefert false, wenn sie schon verschickt war
create or replace function public.kpt_claim(k text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  insert into push_log (key) values (k) on conflict do nothing;
  return found;
end $$;

-- Deutsche Zeit (für Tests lässt sie sich über "kpt.jetzt" vorgeben)
create or replace function public.kpt_now() returns timestamp
language sql stable as $$
  select coalesce(nullif(current_setting('kpt.jetzt', true), '')::timestamp, now() at time zone 'Europe/Berlin');
$$;

-- Ermittelt, wer jetzt welche Mitteilung bekommt, und merkt sich das Verschickte
create or replace function public.kpt_due_messages()
returns table (user_id uuid, title text, body text, tag text)
language plpgsql security definer set search_path = public as $$
declare
  n       timestamp := public.kpt_now();
  fri     date := n::date + ((5 - extract(isodow from n)::int + 7) % 7);
  m       meals;
  koeche  text;
  portion int;
  mitgl   int;
  gaeste  int;
  st      push_state;
  last_id bigint;
  last_ph timestamptz;
begin
  select * into m from meals where day = fri;
  if found then
    select string_agg(p.name, ' & ' order by p.id = m.cook2) into koeche
      from profiles p where p.id in (m.cook1, m.cook2);
    select count(*), coalesce(sum(r.guests), 0) into mitgl, gaeste from rsvps r where r.day = fri and r.coming;
    portion := mitgl + gaeste;

    -- Mittwoch ab 15 Uhr: an alle, die noch nicht geantwortet haben
    if extract(isodow from n) = 3 and n::time >= time '15:00'
       and public.kpt_claim('mittwoch:' || fri) then
      return query
        select p.id, 'KPT: Isst du am Freitag mit?'::text,
               (case when m.title <> '' then 'Es gibt ' || m.title || ', ' else '' end)
               || koeche || case when m.cook2 is null then ' kocht' else ' kochen' end
               || '. Bitte bis heute 23:59 Uhr an- oder abmelden.',
               'kpt-anmeldung'::text
          from profiles p
         where p.active and p.notify_friday and p.id not in (m.cook1, coalesce(m.cook2, m.cook1))
           and not exists (select 1 from rsvps r where r.day = fri and r.user_id = p.id);
    end if;

    -- Donnerstag 7 bis 18 Uhr: Portionen an die Köche
    if extract(isodow from n) = 4 and n::time >= time '07:00' and n::time < time '18:00'
       and public.kpt_claim('donnerstag:' || fri) then
      return query
        select p.id, ('KPT: Einkaufen für ' || portion || case when portion = 1 then ' Portion' else ' Portionen' end)::text,
               'Für Freitag ' || case when mitgl = 1 and gaeste = 0 then 'ist ' else 'sind ' end || mitgl
               || case when mitgl = 1 then ' Mitglied' else ' Mitglieder' end
               || case when gaeste > 0 then ' und ' || gaeste || case when gaeste = 1 then ' Gast' else ' Gäste' end else '' end
               || ' angemeldet. Nachmelden geht noch bis heute 18 Uhr, den Endstand bekommst du heute Abend.',
               'kpt-einkauf'::text
          from profiles p
         where p.active and p.notify_friday and p.id in (m.cook1, coalesce(m.cook2, m.cook1));
    end if;

    -- Donnerstag ab 18:05 Uhr: Endstand an die Köche
    if extract(isodow from n) = 4 and n::time >= time '18:05'
       and public.kpt_claim('donnerstagabend:' || fri) then
      return query
        select p.id, ('KPT: Endstand für Freitag: ' || portion || case when portion = 1 then ' Portion' else ' Portionen' end)::text,
               coalesce('Nach Mittwoch dazugekommen: ' || (
                  select string_agg(q.name || case when r.guests > 0 then ' (+' || r.guests || ')' else '' end, ', ' order by q.name)
                    from rsvps r join profiles q on q.id = r.user_id
                   where r.day = fri and r.coming and r.late and r.user_id not in (m.cook1, coalesce(m.cook2, m.cook1))) || '. ',
                  'Seit Mittwoch hat sich nichts geändert. ')
               || 'Die Anmeldung ist geschlossen, nur die Zahl der Gäste lässt sich noch bis Freitag 12 Uhr ändern.',
               'kpt-endstand'::text
          from profiles p
         where p.active and p.notify_friday and p.id in (m.cook1, coalesce(m.cook2, m.cook1));
    end if;

    -- Freitag ab 19 Uhr: an alle, die mitgegessen und noch nicht bewertet haben
    if extract(isodow from n) = 5 and n::time >= time '19:00'
       and public.kpt_claim('bewerten:' || fri) then
      return query
        select p.id, 'KPT: Wie hat es dir geschmeckt?'::text,
               'Du hast heute ' || coalesce(nullif(m.title, ''), 'das Essen') || ' von ' || koeche
               || ' noch nicht bewertet. Ein paar Kochlöffel dauern nur Sekunden.',
               'kpt-bewerten'::text
          from profiles p
          join rsvps r on r.day = fri and r.user_id = p.id and r.coming
         where p.active and p.notify_friday and p.id not in (m.cook1, coalesce(m.cook2, m.cook1))
           and not exists (select 1 from ratings x where x.day = fri and x.user_id = p.id);
    end if;
  end if;

  select * into st from push_state where id = 1 for update;

  -- Chat: gebündelt, sobald eine Minute Ruhe ist (spätestens nach 4 Minuten)
  if exists (select 1 from messages x where x.id > st.last_message_id
              having max(x.created_at at time zone 'Europe/Berlin') < n - interval '1 minute'
                  or min(x.created_at at time zone 'Europe/Berlin') < n - interval '4 minutes') then
    select max(x.id) into last_id from messages x where x.id > st.last_message_id;
    return query
      select p.id,
             case when count(*) = 1 then 'KPT-Chat: ' || min(a.name)
                  else 'KPT-Chat: ' || count(*) || ' neue Nachrichten' end,
             case when count(*) = 1 then left(min(x.body), 160)
                  else 'Von ' || string_agg(distinct a.name, ', ') || ': ' || left((array_agg(x.body order by x.id desc))[1], 120) end,
             'kpt-chat'::text
        from profiles p
        join messages x on x.id > st.last_message_id and x.id <= last_id and x.user_id <> p.id
        join profiles a on a.id = x.user_id
       where p.active and p.notify_chat
       group by p.id;
    update push_state set last_message_id = last_id where id = 1;
  end if;

  -- Fotos: ebenso gebündelt
  if exists (select 1 from photos f where f.created_at > st.last_photo_at
              having max(f.created_at at time zone 'Europe/Berlin') < n - interval '1 minute'
                  or min(f.created_at at time zone 'Europe/Berlin') < n - interval '4 minutes') then
    select max(f.created_at) into last_ph from photos f where f.created_at > st.last_photo_at;
    return query
      select p.id,
             ('KPT: ' || count(*) || case when count(*) = 1 then ' neues Foto' else ' neue Fotos' end)::text,
             'von ' || string_agg(distinct a.name, ', ') || ' zu '
               || string_agg(distinct coalesce(nullif(e.title, ''), 'dem Essen vom ' || to_char(e.day, 'DD.MM.')), ', '),
             'kpt-fotos'::text
        from profiles p
        join photos f on f.created_at > st.last_photo_at and f.created_at <= last_ph and f.user_id <> p.id
        join profiles a on a.id = f.user_id
        join meals e on e.day = f.day
       where p.active and p.notify_photos
       group by p.id;
    update push_state set last_photo_at = last_ph where id = 1;
  end if;
end $$;

-- Gibt Mitteilungen an die Funktion "push" weiter
create or replace function public.kpt_send(msgs jsonb) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare
  c       push_config;
  payload jsonb;
begin
  select * into c from push_config where id = 1;
  if coalesce(c.function_url, '') = '' or coalesce(c.secret, '') = '' then return 0; end if;
  select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth,
                                      'title', x->>'title', 'body', x->>'body', 'tag', x->>'tag'))
    into payload
    from jsonb_array_elements(msgs) x
    join push_subscriptions s on s.user_id = (x->>'user_id')::uuid;
  if payload is null then return 0; end if;
  perform net.http_post(
    url     := c.function_url,
    body    := jsonb_build_object('messages', payload),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-kpt-secret', c.secret),
    timeout_milliseconds := 30000);
  return jsonb_array_length(payload);
end $$;

-- Läuft jede Minute
create or replace function public.kpt_tick() returns int
language plpgsql security definer set search_path = public as $$
declare
  c push_config;
begin
  select * into c from push_config where id = 1;
  if coalesce(c.function_url, '') = '' or coalesce(c.secret, '') = '' then return 0; end if;   -- noch nicht eingerichtet
  return public.kpt_send((select jsonb_agg(to_jsonb(d)) from public.kpt_due_messages() d));
end $$;

-- Probe-Mitteilung an alle Geräte (im SQL Editor: select public.kpt_test_push();)
create or replace function public.kpt_test_push() returns int
language sql security definer set search_path = public as $$
  select public.kpt_send((select jsonb_agg(jsonb_build_object('user_id', p.id, 'title', 'KPT: Probe-Mitteilung',
                                                             'body', 'Die Mitteilungen funktionieren auf diesem Gerät.', 'tag', 'kpt-test'))
                            from profiles p where p.active));
$$;

revoke execute on function public.kpt_claim(text), public.kpt_due_messages(), public.kpt_send(jsonb), public.kpt_tick(), public.kpt_test_push()
  from public, anon, authenticated;

select cron.schedule('kpt-mitteilungen', '* * * * *', 'select public.kpt_tick()');
