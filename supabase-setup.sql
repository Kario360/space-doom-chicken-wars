-- =====================================================================
-- SPACE DOOM: CHICKEN WARS — Supabase setup for the Endless Run
-- global leaderboard. Run this in: Supabase Dashboard -> SQL Editor.
-- Safe to re-run (idempotent).
-- =====================================================================

-- 1) Table: one score row per player (plus legacy rows).
create table if not exists public.endless_scores (
  id         bigint generated always as identity primary key,
  name       text   not null,
  score      int4   not null,
  wave       int4   not null,
  player_id  text,                         -- hidden per-browser id (added below if missing)
  created_at timestamptz not null default now()
);

-- 1b) Ensure player_id exists on pre-existing tables.
alter table public.endless_scores add column if not exists player_id text;

-- 1c) One row per player_id so we can upsert "keep best".
--     (NULLs are allowed to repeat, so legacy rows without an id are kept.)
alter table public.endless_scores drop constraint if exists endless_scores_player_id_key;
alter table public.endless_scores add  constraint endless_scores_player_id_key unique (player_id);

-- 1d) Fast ordering for the top-N query.
create index if not exists endless_scores_score_idx on public.endless_scores (score desc);

-- 2) Row Level Security: anon can READ; writes go only through the function below.
alter table public.endless_scores enable row level security;

drop policy if exists "anon can read scores" on public.endless_scores;
create policy "anon can read scores"
  on public.endless_scores for select
  to anon
  using (true);

-- (Optional legacy insert policy is intentionally NOT recreated — the game now
--  writes via submit_score(), which validates and keeps each player's best.)
drop policy if exists "anon can add scores" on public.endless_scores;

-- 3) Insert-or-keep-best, keyed on the hidden player id.
--    Called by the game as: POST /rest/v1/rpc/submit_score
create or replace function public.submit_score(p_id text, p_name text, p_score int, p_wave int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- basic validation; silently ignore junk
  if p_id is null
     or char_length(coalesce(p_name,'')) = 0
     or char_length(p_name) > 8
     or p_score < 0 then
    return;
  end if;

  insert into public.endless_scores (player_id, name, score, wave)
  values (p_id, p_name, p_score, p_wave)
  on conflict (player_id) do update
    set name       = excluded.name,
        score      = greatest(endless_scores.score, excluded.score),
        wave       = case when excluded.score > endless_scores.score
                          then excluded.wave else endless_scores.wave end,
        created_at = case when excluded.score > endless_scores.score
                          then now() else endless_scores.created_at end;
end;
$$;

-- 4) Let anonymous web visitors call it.
grant execute on function public.submit_score(text, text, int, int) to anon;
