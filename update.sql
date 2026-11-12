-- KPT – Update vom 12.11.2026 (Stand: Nachmelden bis Donnerstag 18 Uhr, Gäste bis Freitag 12 Uhr,
-- Bewerten ab Freitag 12:30 Uhr). Einmal im Supabase "SQL Editor" ausführen.
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
  if coalesce(current_setting('kpt.koch', true), '') = '1' then      -- Eintrag über "Ich koche"
    new.late := not public.rsvp_soft_open(new.day);
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
