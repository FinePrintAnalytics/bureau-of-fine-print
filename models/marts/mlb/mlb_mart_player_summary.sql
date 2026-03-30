-- mlb_mart_player_summary.sql
-- One row per batter per game with hot/cold flag, splits, park context.
-- Used for content generation and API player endpoint.
-- Historical + today's games.

{{ config(materialized='table') }}

with schedule as (
    select
        *,
        extract(year from game_date) as season
    from {{ ref('mlb_stg_schedule') }}
    where game_status = 'final'
       or game_date = current_date('America/New_York')
),

batter_logs as (
    select * from {{ ref('mlb_stg_game_batter_logs') }}
),

batter_rolling as (
    select * from {{ ref('mlb_int_batter_rolling') }}
),

batter_splits_handedness as (
    select * from {{ ref('mlb_int_batter_splits_handedness') }}
),

batter_splits_park as (
    select * from {{ ref('mlb_int_batter_splits_park') }}
),

parks as (
    select * from {{ ref('mlb_int_park_factors') }}
),

final as (
    select
        s.game_id,
        s.game_date,
        s.season,
        bl.team_id,
        bl.team_abbr,
        bl.player_id,
        bl.player_name,
        bl.batting_order,
        bl.is_starter                                   as is_starting_batter,

        -- is this the home or away batter?
        case when s.home_team_id = bl.team_id then 'home' else 'away' end as home_away,

        -- actual performance this game (null for upcoming)
        bl.ab                                           as actual_ab,
        bl.h                                            as actual_h,
        bl.hr                                           as actual_hr,
        bl.rbi                                          as actual_rbi,
        bl.r                                            as actual_r,
        bl.bb                                           as actual_bb,
        bl.so                                           as actual_so,
        bl.avg                                          as actual_avg,
        bl.obp                                          as actual_obp,
        bl.slg                                          as actual_slg,
        bl.ops                                          as actual_ops,

        -- rolling stats entering game
        br.last7_avg,
        br.last7_obp,
        br.last7_slg,
        br.last7_ops,
        br.last7_hr,
        br.last7_games,
        br.last7_pa,
        br.last15_avg,
        br.last15_obp,
        br.last15_slg,
        br.last15_ops,
        br.last15_hr,
        br.last15_games,
        br.last15_pa,
        br.season_avg,
        br.season_obp,
        br.season_slg,
        br.season_ops,
        br.season_hr,
        br.season_pa,
        br.hot_cold_flag,
        br.has_last7_sample,
        br.has_last15_sample,
        br.has_season_sample,

        -- handedness splits (keyed by pitcher_throws)
        -- join separately for vs LHP and vs RHP
        bhand_l.ops                                     as ops_vs_lhp,
        bhand_l.avg                                     as avg_vs_lhp,
        bhand_l.hr                                      as hr_vs_lhp,
        bhand_l.pa                                      as pa_vs_lhp,
        bhand_r.ops                                     as ops_vs_rhp,
        bhand_r.avg                                     as avg_vs_rhp,
        bhand_r.hr                                      as hr_vs_rhp,
        bhand_r.pa                                      as pa_vs_rhp,

        -- park splits
        bpark.ops                                       as ops_at_venue,
        bpark.avg                                       as avg_at_venue,
        bpark.hr                                        as hr_at_venue,
        bpark.pa                                        as pa_at_venue,

        -- park context
        p.park_type,
        p.is_coors,
        p.is_dome,
        p.capped_park_factor_runs,
        p.capped_park_factor_hr,

        current_timestamp()                             as inserted_at

    from schedule s
    join batter_logs bl on s.game_id = bl.game_id
    left join batter_rolling br
        on bl.player_id = br.player_id
        and bl.game_id = br.game_id
    left join batter_splits_handedness bhand_l
        on bl.player_id = bhand_l.player_id
        and s.season = bhand_l.season
        and bhand_l.pitcher_throws = 'L'
    left join batter_splits_handedness bhand_r
        on bl.player_id = bhand_r.player_id
        and s.season = bhand_r.season
        and bhand_r.pitcher_throws = 'R'
    left join batter_splits_park bpark
        on bl.player_id = bpark.player_id
        and s.venue_id = bpark.venue_id
        and s.season = bpark.season
    left join parks p
        on s.venue_id = p.venue_id
        and s.season = p.park_factor_season
)

select * from final