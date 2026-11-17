-- =============================================================================
-- TD Command - 0008: the ratings of the players of an event.
-- =============================================================================
--
-- A rating report is only accepted by US Chess when the ratings in it are the
-- ratings US Chess holds. The rating a player is seeded with is also what the
-- pairing engine sorts the field by, so a stale rating makes for unfair
-- pairings in the first round.
--
-- The desktop client reads the ratings from the US Chess Ratings API and
-- sends them here. This function is the only way a rating reaches a player
-- who is already registered, so every write is checked and audited.

-- -----------------------------------------------------------------------------
-- Refresh the ratings of the players of an event.
--
-- Each entry names a registration of the event and the ratings US Chess holds
-- for the member behind it. The player record is brought up to date as well,
-- so the next event the player enters starts from the right rating.
-- -----------------------------------------------------------------------------

create or replace function public.refresh_registration_ratings(
  p_tournament_id uuid,
  p_ratings jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tournament public.tournaments%rowtype;
  v_entry jsonb;
  v_registration public.tournament_players%rowtype;
  v_regular integer;
  v_quick integer;
  v_blitz integer;
  v_seed integer;
  v_updated integer := 0;
begin
  if not public.can_register_tournament(p_tournament_id) then
    raise exception 'You do not have permission to change the players of this tournament.';
  end if;

  select * into v_tournament from public.tournaments t where t.id = p_tournament_id;
  if not found then raise exception 'Tournament not found.'; end if;

  if p_ratings is null or jsonb_typeof(p_ratings) <> 'array' then
    raise exception 'The ratings must be a list.';
  end if;

  for v_entry in select * from jsonb_array_elements(p_ratings) loop
    select * into v_registration
    from public.tournament_players tp
    where tp.id = (v_entry ->> 'registration_id')::uuid
      and tp.tournament_id = p_tournament_id;

    if not found then
      raise exception 'A registration in the list does not belong to this tournament.';
    end if;

    -- A rating that is missing or blank keeps the rating that is stored.
    v_regular := case
      when v_entry ? 'regular_rating' and nullif(v_entry ->> 'regular_rating', '') is not null
        then (v_entry ->> 'regular_rating')::integer
      else v_registration.rating_snapshot_regular
    end;
    v_quick := case
      when v_entry ? 'quick_rating' and nullif(v_entry ->> 'quick_rating', '') is not null
        then (v_entry ->> 'quick_rating')::integer
      else v_registration.rating_snapshot_quick
    end;
    v_blitz := case
      when v_entry ? 'blitz_rating' and nullif(v_entry ->> 'blitz_rating', '') is not null
        then (v_entry ->> 'blitz_rating')::integer
      else v_registration.rating_snapshot_blitz
    end;

    if v_regular is not null and (v_regular < 0 or v_regular > 3500) then
      raise exception 'A regular rating must be between 0 and 3500.';
    end if;
    if v_quick is not null and (v_quick < 0 or v_quick > 3500) then
      raise exception 'A quick rating must be between 0 and 3500.';
    end if;
    if v_blitz is not null and (v_blitz < 0 or v_blitz > 3500) then
      raise exception 'A blitz rating must be between 0 and 3500.';
    end if;

    -- The seed is the rating the event is rated under.
    v_seed := case v_tournament.rating_system
      when 'us_chess_quick' then v_quick
      when 'us_chess_blitz' then v_blitz
      else v_regular
    end;

    update public.tournament_players tp set
      rating_snapshot_regular = v_regular,
      rating_snapshot_quick = v_quick,
      rating_snapshot_blitz = v_blitz,
      rating_snapshot_date = current_date,
      seed_rating = v_seed,
      updated_at = now()
    where tp.id = v_registration.id;

    -- The player record follows, so the next event starts from the same
    -- rating. A player who has left the workspace is left alone.
    update public.players p set
      regular_rating = v_regular,
      quick_rating = v_quick,
      blitz_rating = v_blitz,
      rating_source = 'us_chess',
      rating_date = current_date,
      updated_at = now()
    where p.id = v_registration.player_id;

    v_updated := v_updated + 1;
  end loop;

  if v_updated > 0 then
    perform public.log_tournament_action(
      p_tournament_id, 'registration.ratings_refreshed', 'tournament', p_tournament_id::text,
      null, jsonb_build_object('players', v_updated)
    );
  end if;

  return v_updated;
end;
$$;

comment on function public.refresh_registration_ratings(uuid, jsonb) is
  'Takes the ratings US Chess holds for the players of an event and makes them the ratings the event is paired and rated with.';

revoke all on function public.refresh_registration_ratings(uuid, jsonb) from public;
grant execute on function public.refresh_registration_ratings(uuid, jsonb) to authenticated;

notify pgrst, 'reload schema';
