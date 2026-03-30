-- mlb_mart_pitcher_summary.sql
-- One row per starter per game with full signal set.
-- Used for content generation and API pitcher endpoint.
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

pitcher_logs as (
    select * from {{ ref('mlb_stg_game_pitcher_logs') }}
    where is_starter = true
),

pitcher_rolling as (
    select * from {{ ref('mlb_int_pitcher_rolling') }}
),

starter_length as (
    select * from {{ ref('mlb_int_starter_length') }}
),

pitcher_rest as (
    select * from {{ ref('mlb_int_pitcher_splits_rest') }}
),

pitcher_splits_handedness as (
    select * from {{ ref('mlb_int_pitcher_splits_handedness') }}
),

pitcher_splits_park as (
    select * from {{ ref('mlb_int_pitcher_splits_park') }}
),

parks as (
    select * from {{ ref('mlb_int_park_factors') }}
),

final as (
    select
        s.game_id,
        s.game_date,
        s.season,
        pl.team_id,
        pl.team_abbr,
        pl.player_id,
        pl.player_name,
        pl.throws,

        -- is this the home or away SP?
        case when s.home_team_id = pl.team_id then 'home' else 'away' end as home_away,

        -- actual performance this game (null for upcoming)
        round(pl.ip_outs / 3.0, 1)                     as actual_ip,
        pl.er                                           as actual_er,
        pl.so                                           as actual_so,
        pl.bb                                           as actual_bb,
        pl.h                                            as actual_h,
        case when pl.ip_outs > 0
             then round(pl.er * 27.0 / pl.ip_outs, 2)
             else null
        end                                             as actual_era,

        -- rolling stats entering game
        pr.last5_era,
        pr.last5_whip,
        pr.last5_k_per_9,
        pr.last5_bb_per_9,
        pr.last5_hr_per_9,
        pr.last5_games,
        pr.season_era,
        pr.season_whip,
        pr.season_k_per_9,
        pr.season_games,
        pr.season_ip,
        pr.era_trend,
        pr.has_rolling_sample,
        pr.has_season_sample,

        -- durability
        sl.durability_classification,
        sl.avg_ip_per_start,
        sl.last5_avg_ip_per_start,
        sl.quality_start_rate,
        sl.short_outing_rate,
        sl.avg_bullpen_innings_needed,

        -- rest
        prest.days_rest,
        prest.rest_classification,
        prest.is_short_rest,
        prest.is_extra_rest,
        prest.is_long_layoff,

        -- handedness splits (two rows per pitcher per season: L and R batter side)
        phand_l.opp_ops                                 as ops_allowed_vs_lhh,
        phand_l.opp_avg                                 as avg_allowed_vs_lhh,
        phand_l.hr_rate                                 as hr_rate_vs_lhh,
        phand_l.k_rate                                  as k_rate_vs_lhh,
        phand_l.games                                   as games_vs_lhh,
        phand_l.platoon_matchup                         as platoon_matchup_vs_lhh,
        phand_r.opp_ops                                 as ops_allowed_vs_rhh,
        phand_r.opp_avg                                 as avg_allowed_vs_rhh,
        phand_r.hr_rate                                 as hr_rate_vs_rhh,
        phand_r.k_rate                                  as k_rate_vs_rhh,
        phand_r.games                                   as games_vs_rhh,
        phand_r.platoon_matchup                         as platoon_matchup_vs_rhh,

        -- park splits
        ppark.era                                       as era_at_venue,
        ppark.whip                                      as whip_at_venue,
        ppark.games_started                             as starts_at_venue,
        ppark.k_per_9                                   as k9_at_venue,
        ppark.hr_per_9                                  as hr9_at_venue,

        -- park context
        p.park_type,
        p.is_coors,
        p.is_dome,
        p.capped_park_factor_runs,
        p.park_narrative,

        current_timestamp()                             as inserted_at

    from schedule s
    join pitcher_logs pl on s.game_id = pl.game_id
    left join pitcher_rolling pr
        on pl.player_id = pr.player_id
        and pl.game_id = pr.game_id
    left join starter_length sl
        on pl.player_id = sl.player_id
        and s.season = sl.season
    left join pitcher_rest prest
        on pl.player_id = prest.player_id
        and pl.game_id = prest.game_id
    left join pitcher_splits_handedness phand_l
        on pl.player_id = phand_l.player_id
        and s.season = phand_l.season
        and phand_l.batter_side = 'L'
    left join pitcher_splits_handedness phand_r
        on pl.player_id = phand_r.player_id
        and s.season = phand_r.season
        and phand_r.batter_side = 'R'
    left join pitcher_splits_park ppark
        on pl.player_id = ppark.player_id
        and s.venue_id = ppark.venue_id
        and s.season = ppark.season
    left join parks p
        on s.venue_id = p.venue_id
        and s.season = p.park_factor_season
)

select * from final