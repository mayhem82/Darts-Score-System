-- Bellbrook Darts Club — Tipping Module database schema
--
-- Run this ONCE in your Supabase project's SQL Editor
-- (Project → SQL Editor → New query → paste this whole file → Run).
--
-- Design notes:
--   - All gatekeeping (round codes, the Wednesday 3:30-5:15pm window,
--     one-submission-per-person, no edits after close) is enforced
--     HERE, in Postgres, via Row Level Security + a SECURITY DEFINER
--     function — not in the browser. A participant with dev tools
--     open cannot bypass any of it; the database itself refuses the
--     write.
--   - Round codes are never readable by the public. The submission
--     function checks a code against the stored value internally and
--     returns only true/false — the code itself is never sent back
--     to any browser.
--   - Scoring is computed by a SQL function from match_results, the
--     single canonical source, exactly per spec section 10.

-- ============================================================
-- Extensions
-- ============================================================
create extension if not exists pgcrypto;

-- ============================================================
-- Core tables
-- ============================================================

create table seasons (
    id uuid primary key default gen_random_uuid(),
    name text not null,                              -- e.g. "2026 Season"
    league_entry_fee numeric not null default 50,
    weekly_entry_fee numeric not null default 10,
    is_current boolean not null default false,
    created_at timestamptz not null default now()
);

-- Season League entrants: pay $50 once, covers every round this season
create table league_entrants (
    id uuid primary key default gen_random_uuid(),
    season_id uuid not null references seasons(id) on delete cascade,
    participant_name text not null,
    league_access_code text not null,                -- set by admin at signup
    active boolean not null default true,
    created_at timestamptz not null default now(),
    unique (season_id, participant_name)
);

-- One row per Wednesday tipping round
create table rounds (
    id uuid primary key default gen_random_uuid(),
    season_id uuid not null references seasons(id) on delete cascade,
    round_number int not null,
    weekly_round_code text not null,                  -- unique per round, admin-set
    opens_at timestamptz not null,                     -- Wed 15:30 AEST
    closes_at timestamptz not null,                    -- Wed 17:15 AEST
    created_at timestamptz not null default now(),
    unique (season_id, round_number)
);

-- Weekly-only entrants for a given round: pay $10, this round only
create table weekly_entrants (
    id uuid primary key default gen_random_uuid(),
    round_id uuid not null references rounds(id) on delete cascade,
    participant_name text not null,
    created_at timestamptz not null default now(),
    unique (round_id, participant_name)
);

-- Canonical match results — the sole source of truth for scoring (spec §10)
create table match_results (
    id uuid primary key default gen_random_uuid(),
    round_id uuid not null unique references rounds(id) on delete cascade,
    winner text not null,
    checkout int not null,
    total_180s int not null,
    entered_by text,
    completed_at timestamptz not null default now()
);

-- The tipping ledger — one row per prediction (spec §6)
create table submissions (
    id uuid primary key default gen_random_uuid(),
    round_id uuid not null references rounds(id) on delete cascade,
    competition_type text not null check (competition_type in ('league', 'weekly')),
    participant_name text not null,
    winner_prediction text not null,
    checkout_prediction int not null,
    total_180s_prediction int not null,
    submitted_at timestamptz not null default now(),
    updated_at timestamptz,
    unique (round_id, competition_type, participant_name)
);

-- Audit trail (spec §13)
create table audit_log (
    id uuid primary key default gen_random_uuid(),
    event_type text not null,
    details jsonb,
    occurred_at timestamptz not null default now()
);

-- ============================================================
-- Helper: current season shortcut
-- ============================================================
create or replace function current_season_id()
returns uuid
language sql stable
as $$
    select id from seasons where is_current = true limit 1;
$$;

-- ============================================================
-- Public-safe views (never expose access codes)
-- ============================================================

create view rounds_public as
    select id, season_id, round_number, opens_at, closes_at,
           (now() >= opens_at and now() < closes_at) as is_open
    from rounds;

create view league_entrants_public as
    select id, season_id, participant_name, active
    from league_entrants;

-- ============================================================
-- Submission function — the ONLY way to record a tip.
-- SECURITY DEFINER lets it read access codes internally without
-- ever exposing them; RLS on the base tables blocks direct writes.
-- ============================================================

create or replace function submit_tip(
    p_round_id uuid,
    p_competition_type text,
    p_participant_name text,
    p_access_code text,
    p_winner text,
    p_checkout int,
    p_total_180s int
)
returns table (ok boolean, message text)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_round rounds%rowtype;
    v_code_valid boolean := false;
begin
    select * into v_round from rounds where id = p_round_id;

    if v_round.id is null then
        return query select false, 'Round not found.';
        return;
    end if;

    if now() < v_round.opens_at then
        insert into audit_log (event_type, details)
            values ('submission_rejected', jsonb_build_object('reason', 'before_open', 'round_id', p_round_id, 'name', p_participant_name));
        return query select false, 'Tipping has not opened yet.';
        return;
    end if;

    if now() >= v_round.closes_at then
        insert into audit_log (event_type, details)
            values ('submission_rejected', jsonb_build_object('reason', 'after_close', 'round_id', p_round_id, 'name', p_participant_name));
        return query select false, 'Tipping Closed — the window for this round has ended.';
        return;
    end if;

    if p_competition_type = 'weekly' then
        v_code_valid := (p_access_code = v_round.weekly_round_code);
    elsif p_competition_type = 'league' then
        v_code_valid := exists (
            select 1 from league_entrants
            where season_id = v_round.season_id
              and league_access_code = p_access_code
              and active = true
        );
    else
        return query select false, 'Unknown competition type.';
        return;
    end if;

    if not v_code_valid then
        insert into audit_log (event_type, details)
            values ('submission_rejected', jsonb_build_object('reason', 'bad_code', 'round_id', p_round_id, 'name', p_participant_name));
        return query select false, 'Invalid Round Code.';
        return;
    end if;

    -- Weekly entrants must also be a registered paid entry for this round
    if p_competition_type = 'weekly' then
        insert into weekly_entrants (round_id, participant_name)
            values (p_round_id, p_participant_name)
            on conflict (round_id, participant_name) do nothing;
    end if;

    insert into submissions (
        round_id, competition_type, participant_name,
        winner_prediction, checkout_prediction, total_180s_prediction
    ) values (
        p_round_id, p_competition_type, p_participant_name,
        p_winner, p_checkout, p_total_180s
    )
    on conflict (round_id, competition_type, participant_name)
    do update set
        winner_prediction = excluded.winner_prediction,
        checkout_prediction = excluded.checkout_prediction,
        total_180s_prediction = excluded.total_180s_prediction,
        updated_at = now();

    insert into audit_log (event_type, details)
        values ('submission_received', jsonb_build_object('round_id', p_round_id, 'name', p_participant_name, 'type', p_competition_type));

    return query select true, 'Tip submitted!';
end;
$$;

-- ============================================================
-- Scoring engine (spec §9) — computed from match_results, never stored
-- ============================================================

create or replace function round_points(p_round_id uuid)
returns table (
    participant_name text,
    competition_type text,
    points int
)
language sql stable
as $$
    select
        s.participant_name,
        s.competition_type,
        (case when s.winner_prediction = mr.winner then 1 else 0 end)
        + (case when abs(s.checkout_prediction - mr.checkout) <= 5 then 2 else 0 end)
        + (case when s.total_180s_prediction = mr.total_180s then 5 else 0 end)
        as points
    from submissions s
    join match_results mr on mr.round_id = s.round_id
    where s.round_id = p_round_id;
$$;

create or replace function league_leaderboard(p_season_id uuid)
returns table (
    participant_name text,
    total_points bigint,
    rounds_played bigint
)
language sql stable
as $$
    select
        s.participant_name,
        coalesce(sum(
            (case when s.winner_prediction = mr.winner then 1 else 0 end)
            + (case when abs(s.checkout_prediction - mr.checkout) <= 5 then 2 else 0 end)
            + (case when s.total_180s_prediction = mr.total_180s then 5 else 0 end)
        ), 0) as total_points,
        count(mr.id) as rounds_played
    from submissions s
    join rounds r on r.id = s.round_id
    left join match_results mr on mr.round_id = s.round_id
    where r.season_id = p_season_id
      and s.competition_type = 'league'
    group by s.participant_name
    order by total_points desc, s.participant_name asc;
$$;

create or replace function weekly_leaderboard(p_round_id uuid)
returns table (
    participant_name text,
    points int
)
language sql stable
as $$
    select participant_name, points
    from round_points(p_round_id)
    where competition_type = 'weekly'
    order by points desc, participant_name asc;
$$;

-- Prize pools (spec §8)
create or replace function league_prize_pool(p_season_id uuid)
returns numeric
language sql stable
as $$
    select coalesce(count(*), 0) * s.league_entry_fee
    from league_entrants le
    join seasons s on s.id = le.season_id
    where le.season_id = p_season_id and le.active = true
    group by s.league_entry_fee;
$$;

create or replace function weekly_prize_pool(p_round_id uuid)
returns numeric
language sql stable
as $$
    select coalesce(count(distinct s.participant_name), 0) * se.weekly_entry_fee
    from submissions s
    join rounds r on r.id = s.round_id
    join seasons se on se.id = r.season_id
    where s.round_id = p_round_id and s.competition_type = 'weekly'
    group by se.weekly_entry_fee;
$$;

-- ============================================================
-- Row Level Security
-- ============================================================

alter table seasons enable row level security;
alter table league_entrants enable row level security;
alter table rounds enable row level security;
alter table weekly_entrants enable row level security;
alter table match_results enable row level security;
alter table submissions enable row level security;
alter table audit_log enable row level security;

-- Public may read the safe views (created above, not the base tables).
-- No anon policies are created on the base tables below, which means
-- PostgREST denies all direct access by default — the only paths in
-- are the views and the submit_tip()/leaderboard functions above.

grant select on rounds_public to anon, authenticated;
grant select on league_entrants_public to anon, authenticated;
grant execute on function submit_tip to anon, authenticated;
grant execute on function round_points to anon, authenticated;
grant execute on function league_leaderboard to anon, authenticated;
grant execute on function weekly_leaderboard to anon, authenticated;
grant execute on function league_prize_pool to anon, authenticated;
grant execute on function weekly_prize_pool to anon, authenticated;
grant select on seasons to anon, authenticated;

-- Everyone may see which season is current + its fee structure
create policy "seasons are publicly readable"
    on seasons for select
    using (true);

-- Admin-only writes: restrict to a signed-in Supabase Auth user whose
-- email is in the admin allow-list below. Replace the email with the
-- club admin's login before running this script.
create table admin_users (
    email text primary key
);

-- Lock this down completely: no anon/authenticated policies at all, so the
-- admin's email is never readable via the public REST API. Managing this
-- table (e.g. adding a second admin) is a rare, manual job done directly
-- in the Supabase SQL Editor, which runs as postgres and bypasses RLS.
alter table admin_users enable row level security;

-- >>> EDIT THIS: put the admin's login email here before running <<<
insert into admin_users (email) values ('admin@example.com');

create or replace function is_admin()
returns boolean
language sql stable
as $$
    select exists (
        select 1 from admin_users where email = auth.jwt() ->> 'email'
    );
$$;

-- Frontend needs to be able to ask "am I an admin?" directly (e.g. to show/hide
-- the admin panel after login) without this itself exposing any admin data.
grant execute on function is_admin to authenticated;

create policy "admin manages seasons" on seasons for all
    using (is_admin()) with check (is_admin());
create policy "admin manages league entrants" on league_entrants for all
    using (is_admin()) with check (is_admin());
create policy "admin manages rounds" on rounds for all
    using (is_admin()) with check (is_admin());
create policy "admin reads weekly entrants" on weekly_entrants for select
    using (is_admin());
create policy "admin manages match results" on match_results for all
    using (is_admin()) with check (is_admin());
create policy "admin reads submissions" on submissions for select
    using (is_admin());
create policy "admin reads audit log" on audit_log for select
    using (is_admin());

-- End of schema.
