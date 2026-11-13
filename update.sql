-- KPT – Update vom 12.11.2026 (Stand: Nachmelden bis Donnerstag 18 Uhr, Gäste bis Freitag 12 Uhr,
-- Bewerten ab Freitag 12:30 Uhr,
-- frühere Essen nachtragen, Teilnehmer von Hand eintragen,
-- getrennte Einkaufsbeträge bei zwei Köchen, goldener Löffel ab 2027,
-- Mitteilungen über Supabase). Einmal im Supabase "SQL Editor" ausführen.
-- Bringt jede frühere Fassung der Datenbank auf den aktuellen Stand; mehrfaches Ausführen schadet nicht.

alter table public.rsvps add column if not exists late boolean not null default false;

drop trigger if exists rsvps_notify on public.rsvps;
drop function if exists public.rsvps_notify();
alter table public.club drop column if exists github_token;
alter table public.club drop column if exists github_repo;

create or replace function public.rsvp_soft_open(d date) returns boolean
language sql stable as $$
  select (now() at time zone 'Europe/Berlin') < (d - 1)::timestamp;
$$;

create or replace function public.rsvp_open(d date) returns boolean
language sql stable as $$
  select (now() at time zone 'Europe/Berlin') < (d - 1)::timestamp + interval '18 hours';
$$;

create or replace function public.rsvp_guests_open(d date) returns boolean
language sql stable as $$
  select (now() at time zone 'Europe/Berlin') < d::timestamp + interval '12 hours';
$$;

create or replace function public.rate_open(d date) returns boolean
language sql stable as $$
  select (now() at time zone 'Europe/Berlin') >= d::timestamp + interval '12 hours 30 minutes';
$$;

create or replace function public.claim_friday(d date) returns void
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

create or replace function public.rsvps_before() returns trigger
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
drop trigger if exists rsvps_before on public.rsvps;
create trigger rsvps_before before insert or update on public.rsvps
  for each row execute function public.rsvps_before();

drop policy if exists rsvps_update on public.rsvps;
create policy rsvps_update on public.rsvps for update to authenticated
  using (user_id = auth.uid() and is_member() and rsvp_guests_open(day))
  with check (user_id = auth.uid() and is_member() and rsvp_guests_open(day));

create or replace function public.may_rate(d date) returns boolean
language sql stable security definer set search_path = public as $$
  select is_member()
     and rate_open(d)
     and exists (select 1 from rsvps r where r.day = d and r.user_id = auth.uid() and r.coming)
     and exists (select 1 from meals m where m.day = d
                 and m.cook1 <> auth.uid()
                 and (m.cook2 is null or m.cook2 <> auth.uid()));
$$;

-- Admin: ein früheres Essen nachtragen (Koch, Gericht, wer mitgegessen hat)
create or replace function public.admin_add_past_meal(d date, c1 uuid, c2 uuid, t text, attendees uuid[]) returns void
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
create or replace function public.admin_delete_meal(d date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Nur für Admins.'; end if;
  if d >= berlin_today() then raise exception 'Nur vergangene Essen lassen sich löschen.'; end if;
  delete from rsvps where day = d;
  delete from meals where day = d;
end $$;

revoke execute on function public.admin_add_past_meal(date, uuid, uuid, text, uuid[]), public.admin_delete_meal(date) from public, anon;
grant execute on function public.admin_add_past_meal(date, uuid, uuid, text, uuid[]), public.admin_delete_meal(date) to authenticated;

-- Admin: bei einem Essen von Hand eintragen, wer mitisst oder mitgegessen hat (auch nach Anmeldeschluss)
create or replace function public.admin_set_attendance(d date, who uuid, is_coming boolean) returns void
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

drop policy if exists meals_update on public.meals;
create policy meals_update on public.meals for update to authenticated
  using (is_member() and (auth.uid() in (cook1, cook2) or is_admin()))
  with check (is_member() and (auth.uid() in (cook1, cook2) or is_admin()));

-- Getrennte Einkaufsbeträge bei zwei Köchen ("cost" = Koch 1, "cost2" = Koch 2)
alter table public.meals add column if not exists cost2 numeric(8,2) check (cost2 is null or cost2 between 0 and 5000);
grant update (cost2) on public.meals to authenticated;

create or replace function public.release_friday(d date, who uuid default null) returns void
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

-- Goldener Löffel
alter table public.ratings add column if not exists gold boolean not null default false;
alter table public.ratings add column if not exists gold_reason text not null default '' check (char_length(gold_reason) <= 1000);
alter table public.ratings drop constraint if exists ratings_gold_check;
alter table public.ratings add constraint ratings_gold_check check (not gold or (spoons = 5 and char_length(btrim(gold_reason)) >= 20));
create unique index if not exists ratings_gold_per_year on public.ratings (user_id, (extract(year from day))) where gold;

-- Vergabe ab Essen vom 1. Januar 2027, jeweils ab Freitag 12:30 Uhr bis Donnerstag 23:59 Uhr danach
create or replace function public.gold_open(d date) returns boolean
language sql stable as $$
  select d >= date '2027-01-01'
     and public.rate_open(d)
     and (now() at time zone 'Europe/Berlin') < (d + 7)::timestamp;
$$;

create or replace function public.ratings_gold() returns trigger
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
drop trigger if exists ratings_gold on public.ratings;
create trigger ratings_gold before insert or update on public.ratings
  for each row execute function public.ratings_gold();

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
