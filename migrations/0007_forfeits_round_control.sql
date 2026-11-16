-- TD Command: Release 2.1 forfeits, round control, and tournament announcements.
--
-- Run this once in the Supabase SQL Editor after 0006_public_events.sql.
--
-- This migration adds three things:
--
--   1. A forfeit. A player who does not show loses the game by forfeit. The
--      score of the board stays a normal result, so the standings, the
--      crosstables, and the prize money need no change at all. The flag says
--      which side gave the game up, and the US Chess rating report writes the
--      US Chess result code: X for the player who won by forfeit, F for the
--      player who forfeited.
--
--   2. A round control view that tells the director, in one place, where
--      every section of the event stands and what is left to do.
--
--   3. The tournament announcement. The settings a director fills in once
--      are kept beside the event, so the announcement can be rebuilt at any
--      time without hunting for the details again.

-- ---------------------------------------------------------------------------
-- Forfeits
-- ---------------------------------------------------------------------------

alter table public.tournament_pairings
  add column if not exists forfeit_side text;

alter table public.tournament_pairings
  drop constraint if exists tournament_pairings_forfeit_side_check;

alter table public.tournament_pairings
  add constraint tournament_pairings_forfeit_side_check
  check (forfeit_side is null or forfeit_side in ('white', 'black'));

comment on column public.tournament_pairings.forfeit_side is
  'Which side gave the game up: white or black. Null when the game was played.';

-- The standings view is rebuilt here so the live database and a fresh
-- install hold exactly the same view.
--
-- The view is dropped and made again rather than replaced, because a view
-- cannot lose a column when it is replaced, and the columns of this view
-- must stay exactly as migration 0004 left them.
drop view if exists public.tournament_standings;

create view public.tournament_standings
with (security_invoker = true)
as
select
  tp.section_id,
  tp.tournament_id,
  tp.player_id,
  tp.id as registration_id,
  p.full_name,
  p.us_chess_id,
  coalesce(tp.seed_rating, p.regular_rating) as rating,
  tp.status as registration_status,
  count(pg.id) filter (where pg.result is not null) as games_played,
  count(pg.id) filter (where pg.result = '1-0' and pg.white_registration_id = tp.id) as wins,
  count(pg.id) filter (where pg.result = '0-1' and pg.black_registration_id = tp.id) as wins_as_black,
  count(pg.id) filter (where pg.result = '1/2-1/2') as draws,
  count(pg.id) filter (where pg.result = '1-0' and pg.black_registration_id = tp.id) as losses,
  count(pg.id) filter (where pg.result = '0-1' and pg.white_registration_id = tp.id) as losses_as_white,
  count(pg.id) filter (where pg.is_bye) as byes,
  coalesce(sum(
    case
      when pg.result = '1-0' and pg.white_registration_id = tp.id then 1.0
      when pg.result = '0-1' and pg.black_registration_id = tp.id then 1.0
      when pg.result = '1/2-1/2' then 0.5
      when pg.is_bye and (pg.white_registration_id = tp.id or pg.black_registration_id = tp.id) then 1.0
      else 0
    end
  ), 0) as score
from public.tournament_players tp
join public.players p on p.id = tp.player_id
left join public.tournament_pairings pg
  on pg.white_registration_id = tp.id or pg.black_registration_id = tp.id
group by tp.section_id, tp.tournament_id, tp.player_id, tp.id, p.full_name, p.us_chess_id, tp.seed_rating, p.regular_rating, tp.status;

grant select on public.tournament_standings to authenticated;
revoke all on public.tournament_standings from anon;

comment on view public.tournament_standings is
  'Raw points and game counts per player in a section. Tiebreaks are computed in the client.';

-- A result that is recorded in the ordinary way clears any forfeit flag, so
-- a board can be corrected without leaving an old forfeit behind.
create or replace function public.record_pairing_result(
  p_pairing_id uuid,
  p_result text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pairing public.tournament_pairings%rowtype;
  v_before jsonb;
  v_after jsonb;
begin
  select * into v_pairing from public.tournament_pairings p where p.id = p_pairing_id;
  if not found then raise exception 'Pairing not found.'; end if;

  if not public.can_manage_tournament(v_pairing.tournament_id) then
    raise exception 'You do not have permission to record this result.';
  end if;

  if p_result is not null and p_result not in ('1-0', '0-1', '1/2-1/2') then
    raise exception 'A result must be 1-0, 0-1, or 1/2-1/2.';
  end if;

  if p_result is not null and v_pairing.is_bye then
    raise exception 'A bye does not take a result.';
  end if;

  select to_jsonb(p) into v_before from public.tournament_pairings p where p.id = p_pairing_id;

  update public.tournament_pairings p set
    result = p_result,
    forfeit_side = null,
    updated_at = now()
  where p.id = p_pairing_id;

  select to_jsonb(p) into v_after from public.tournament_pairings p where p.id = p_pairing_id;

  if not exists (
    select 1 from public.tournament_pairings p
    where p.round_id = v_pairing.round_id and p.result is null
  ) then
    update public.tournament_rounds r set status = 'completed', updated_at = now()
    where r.id = v_pairing.round_id;
  else
    update public.tournament_rounds r set status = 'paired', updated_at = now()
    where r.id = v_pairing.round_id;
  end if;

  perform public.log_tournament_action(
    v_pairing.tournament_id, 'pairing.result_recorded', 'pairing', p_pairing_id::text,
    v_before, v_after, null
  );
end;
$$;

revoke all on function public.record_pairing_result(uuid, text) from public;
grant execute on function public.record_pairing_result(uuid, text) to authenticated;

-- Record a board that was won by forfeit.
--
-- p_forfeit_side is the side that gave the game up: 'white' or 'black'. The
-- board keeps a normal score, so nothing else in the app has to change.
create or replace function public.record_pairing_forfeit(
  p_pairing_id uuid,
  p_forfeit_side text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pairing public.tournament_pairings%rowtype;
  v_before jsonb;
  v_after jsonb;
  v_result text;
begin
  select * into v_pairing from public.tournament_pairings p where p.id = p_pairing_id;
  if not found then raise exception 'Pairing not found.'; end if;

  if not public.can_manage_tournament(v_pairing.tournament_id) then
    raise exception 'You do not have permission to record this result.';
  end if;

  if p_forfeit_side not in ('white', 'black') then
    raise exception 'A forfeit must name the side that gave the game up.';
  end if;

  if v_pairing.is_bye then
    raise exception 'A bye does not take a result.';
  end if;

  if v_pairing.white_registration_id is null or v_pairing.black_registration_id is null then
    raise exception 'A forfeit needs two players on the board.';
  end if;

  -- The player who did not show loses the board.
  if p_forfeit_side = 'white' then
    v_result := '0-1';
  else
    v_result := '1-0';
  end if;

  select to_jsonb(p) into v_before from public.tournament_pairings p where p.id = p_pairing_id;

  update public.tournament_pairings p set
    result = v_result,
    forfeit_side = p_forfeit_side,
    updated_at = now()
  where p.id = p_pairing_id;

  select to_jsonb(p) into v_after from public.tournament_pairings p where p.id = p_pairing_id;

  if not exists (
    select 1 from public.tournament_pairings p
    where p.round_id = v_pairing.round_id and p.result is null
  ) then
    update public.tournament_rounds r set status = 'completed', updated_at = now()
    where r.id = v_pairing.round_id;
  else
    update public.tournament_rounds r set status = 'paired', updated_at = now()
    where r.id = v_pairing.round_id;
  end if;

  perform public.log_tournament_action(
    v_pairing.tournament_id, 'pairing.forfeit_recorded', 'pairing', p_pairing_id::text,
    v_before, v_after, null
  );
end;
$$;

revoke all on function public.record_pairing_forfeit(uuid, text) from public;
grant execute on function public.record_pairing_forfeit(uuid, text) to authenticated;

-- Clearing a result clears the forfeit with it.
create or replace function public.clear_pairing_result(p_pairing_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pairing public.tournament_pairings%rowtype;
  v_before jsonb;
  v_after jsonb;
begin
  select * into v_pairing from public.tournament_pairings p where p.id = p_pairing_id;
  if not found then raise exception 'Pairing not found.'; end if;

  if not public.can_manage_tournament(v_pairing.tournament_id) then
    raise exception 'You do not have permission to change this result.';
  end if;

  select to_jsonb(p) into v_before from public.tournament_pairings p where p.id = p_pairing_id;

  update public.tournament_pairings p
    set result = null, forfeit_side = null, updated_at = now()
    where p.id = p_pairing_id;

  select to_jsonb(p) into v_after from public.tournament_pairings p where p.id = p_pairing_id;

  update public.tournament_rounds r set status = 'paired', updated_at = now() where r.id = v_pairing.round_id;

  perform public.log_tournament_action(
    v_pairing.tournament_id, 'pairing.result_cleared', 'pairing', p_pairing_id::text,
    v_before, v_after, null
  );
end;
$$;

revoke all on function public.clear_pairing_result(uuid) from public;
grant execute on function public.clear_pairing_result(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Round control
-- ---------------------------------------------------------------------------

-- Where every section of the event stands.
--
-- One row per section: how many players it holds, how many rounds are
-- planned, how many rounds are paired, how many are finished, and how many
-- boards are still waiting for a result.
create or replace view public.tournament_round_control
with (security_invoker = true)
as
select
  s.id as section_id,
  s.tournament_id,
  s.name as section_name,
  s.rounds_planned as section_rounds_planned,
  coalesce(t.rounds_planned, s.rounds_planned) as rounds_planned,
  t.pairing_method,
  s.pairing_method as section_pairing_method,
  (
    select count(*)::integer from public.tournament_players tp
    where tp.section_id = s.id
      and tp.status in ('registered', 'confirmed', 'checked_in')
  ) as player_count,
  (
    select count(*)::integer from public.tournament_rounds r
    where r.section_id = s.id
  ) as rounds_created,
  (
    select count(*)::integer from public.tournament_rounds r
    where r.section_id = s.id and r.status = 'paired'
  ) as rounds_paired,
  (
    select count(*)::integer from public.tournament_rounds r
    where r.section_id = s.id and r.status = 'completed'
  ) as rounds_completed,
  (
    select count(*)::integer from public.tournament_pairings p
    join public.tournament_rounds r on r.id = p.round_id
    where r.section_id = s.id and p.result is null and not p.is_bye
  ) as boards_pending
from public.tournament_sections s
join public.tournaments t on t.id = s.tournament_id;

grant select on public.tournament_round_control to authenticated;
revoke all on public.tournament_round_control from anon;

comment on view public.tournament_round_control is
  'Where every section of an event stands: players, rounds, and boards waiting for a result.';

-- ---------------------------------------------------------------------------
-- The tournament announcement
-- ---------------------------------------------------------------------------

-- The details a director fills in for the announcement. They belong to the
-- event, so a second director can rebuild the announcement without asking.
create table if not exists public.tournament_announcements (
  tournament_id uuid primary key references public.tournaments(id) on delete cascade,
  organizer text,
  contact_email text,
  contact_phone text,
  website text,
  sponsor text,
  prize_distribution text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.tournament_announcements is
  'The details of the tournament announcement, kept beside the event.';

alter table public.tournament_announcements enable row level security;

drop policy if exists "tournament announcements are readable by members" on public.tournament_announcements;
create policy "tournament announcements are readable by members"
  on public.tournament_announcements for select
  using (public.can_access_tournament(tournament_id));

drop policy if exists "tournament announcements are written by managers" on public.tournament_announcements;
create policy "tournament announcements are written by managers"
  on public.tournament_announcements for all
  using (public.can_manage_tournament(tournament_id))
  with check (public.can_manage_tournament(tournament_id));

-- Save the announcement details of an event.
create or replace function public.save_tournament_announcement(
  p_tournament_id uuid,
  p_organizer text default null,
  p_contact_email text default null,
  p_contact_phone text default null,
  p_website text default null,
  p_sponsor text default null,
  p_prize_distribution text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.can_manage_tournament(p_tournament_id) then
    raise exception 'You do not have permission to edit this tournament.';
  end if;

  insert into public.tournament_announcements (
    tournament_id, organizer, contact_email, contact_phone, website, sponsor, prize_distribution
  )
  values (
    p_tournament_id,
    nullif(trim(coalesce(p_organizer, '')), ''),
    nullif(trim(coalesce(p_contact_email, '')), ''),
    nullif(trim(coalesce(p_contact_phone, '')), ''),
    nullif(trim(coalesce(p_website, '')), ''),
    nullif(trim(coalesce(p_sponsor, '')), ''),
    nullif(trim(coalesce(p_prize_distribution, '')), '')
  )
  on conflict (tournament_id) do update set
    organizer = excluded.organizer,
    contact_email = excluded.contact_email,
    contact_phone = excluded.contact_phone,
    website = excluded.website,
    sponsor = excluded.sponsor,
    prize_distribution = excluded.prize_distribution,
    updated_at = now();

  perform public.log_tournament_action(
    p_tournament_id, 'tournament.announcement_saved', 'tournament', p_tournament_id::text,
    null, jsonb_build_object('organizer', p_organizer), null
  );
end;
$$;

revoke all on function public.save_tournament_announcement(uuid, text, text, text, text, text, text) from public;
grant execute on function public.save_tournament_announcement(uuid, text, text, text, text, text, text) to authenticated;

-- Ask PostgREST to refresh its schema cache so the new tables and views are
-- immediately available to the desktop client.
notify pgrst, 'reload schema';
