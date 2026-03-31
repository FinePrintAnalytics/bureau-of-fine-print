-- mlb_mart_game_card.sql
-- One row per game with all pre-game signals aggregated.
-- Primary input for content generation and mlb_mart_game_scores.
-- Covers all historical games + today's games.
-- SP data joined directly from game_pitcher_logs (is_starter=true) +
-- mlb_int_pitcher_rolling, bypassing mlb_int_starting_pitcher_profile
-- which is live-only (depends on lineups table).

{{ config(materialized='table') }}

with schedule as (
    select
        *,
        extract(year from game_date) as season
    from {{ ref('mlb_stg_schedule') }}
    where 
        --game_status = 'final'
       --or 
       game_date = current_date('America/New_York')
),

game_results as (
    select * from {{ ref('mlb_stg_game_results') }}
),

-- identify starters per game from pitcher logs
game_starters as (
    select
        game_id,
        team_id,
        team_abbr,
        player_id                                       as sp_player_id,
        player_name                                     as sp_name,
        throws                                          as sp_throws,
        ip_outs                                         as sp_ip_outs,
        round(ip_outs / 3.0, 1)                        as sp_ip,
        er                                              as sp_er,
        so                                              as sp_so,
        bb                                              as sp_bb,
        h                                               as sp_h
    from {{ ref('mlb_stg_game_pitcher_logs') }}
    where is_starter = true
),

-- rolling pitcher stats entering each game
pitcher_rolling as (
    select * from {{ ref('mlb_int_pitcher_rolling') }}
),

-- starter length / durability
starter_length as (
    select * from {{ ref('mlb_int_starter_length') }}
),

-- rest splits
pitcher_rest as (
    select
        player_id,
        game_id,
        days_rest,
        rest_classification,
        is_short_rest,
        is_extra_rest,
        is_long_layoff
    from {{ ref('mlb_int_pitcher_splits_rest') }}
),

-- team rolling
team_rolling as (
    select * from {{ ref('mlb_int_team_rolling') }}
),

-- bullpen rolling
bullpen as (
    select * from {{ ref('mlb_int_bullpen_rolling') }}
),

-- park factors
parks as (
    select * from {{ ref('mlb_int_park_factors') }}
),

-- weather
weather as (
    select * from {{ ref('mlb_int_weather_signals') }}
),

-- ump tendencies
umps as (
    select * from {{ ref('mlb_int_ump_tendencies') }}
),

-- ump assignments
ump_assignments as (
    select
        game_id,
        max(case when position = 'HP' then ump_id end)      as hp_ump_id,
        max(case when position = 'HP' then ump_name end)    as hp_ump_name
    from {{ ref('mlb_stg_ump_assignments') }}
    group by 1
),

-- team game context (rest, travel, streaks, b2b)
context as (
    select * from {{ ref('mlb_int_team_game_context') }}
),

-- head to head
h2h as (
    select * from {{ ref('mlb_int_head_to_head') }}
),

-- odds
odds as (
    select game_id,
        coalesce(
            max(case when snapshot_type = 'closing' then home_ml end),
            max(case when snapshot_type = 'opening' then home_ml end)
        ) as home_ml,
        coalesce(
            max(case when snapshot_type = 'closing' then away_ml end),
            max(case when snapshot_type = 'opening' then away_ml end)
        ) as away_ml,
        coalesce(
            max(case when snapshot_type = 'closing' then home_runline end),
            max(case when snapshot_type = 'opening' then home_runline end)
        ) as home_runline,
        coalesce(
            max(case when snapshot_type = 'closing' then home_runline_price end),
            max(case when snapshot_type = 'opening' then home_runline_price end)
        ) as home_runline_price,
        coalesce(
            max(case when snapshot_type = 'closing' then away_runline end),
            max(case when snapshot_type = 'opening' then away_runline end)
        ) as away_runline,
        coalesce(
            max(case when snapshot_type = 'closing' then away_runline_price end),
            max(case when snapshot_type = 'opening' then away_runline_price end)
        ) as away_runline_price,
        coalesce(
            max(case when snapshot_type = 'closing' then total_line end),
            max(case when snapshot_type = 'opening' then total_line end)
        ) as total_line,
        coalesce(
            max(case when snapshot_type = 'closing' then over_price end),
            max(case when snapshot_type = 'opening' then over_price end)
        ) as over_price,
        coalesce(
            max(case when snapshot_type = 'closing' then under_price end),
            max(case when snapshot_type = 'opening' then under_price end)
        ) as under_price,
        coalesce(
            max(case when snapshot_type = 'closing' then bookmaker end),
            max(case when snapshot_type = 'opening' then bookmaker end)
        ) as bookmaker
    from `project-71e6f4ed-bf24-4c0f-bb0.mlb_raw.odds`
    group by game_id
),

-- assemble home and away SP per game
home_sp as (
    select
        gs.game_id,
        gs.sp_player_id                                 as home_sp_id,
        gs.sp_name                                      as home_sp_name,
        gs.sp_throws                                    as home_sp_throws,
        gs.sp_ip_outs                                   as home_sp_ip_outs,
        gs.sp_ip                                        as home_sp_ip,
        gs.sp_er                                        as home_sp_er,
        gs.sp_so                                        as home_sp_so,
        gs.sp_bb                                        as home_sp_bb,
        pr.last5_era                                    as home_sp_last5_era,
        pr.last5_whip                                   as home_sp_last5_whip,
        pr.last5_k_per_9                                as home_sp_last5_k9,
        pr.season_era                                   as home_sp_season_era,
        pr.era_trend                                    as home_sp_era_trend,
        pr.has_rolling_sample                           as home_sp_has_rolling,
        sl.durability_classification                    as home_sp_durability,
        sl.avg_ip_per_start                             as home_sp_avg_ip,
        sl.quality_start_rate                           as home_sp_qs_rate,
        sl.short_outing_rate                            as home_sp_short_outing_rate,
        sl.avg_bullpen_innings_needed                   as home_sp_bp_innings_needed,
        prest.days_rest                                 as home_sp_days_rest,
        prest.rest_classification                       as home_sp_rest_classification,
        prest.is_short_rest                             as home_sp_is_short_rest,
        prest.is_extra_rest                             as home_sp_is_extra_rest,
        prest.is_long_layoff                            as home_sp_is_long_layoff
    from schedule s
    left join game_starters gs
        on s.game_id = gs.game_id
        and s.home_team_id = gs.team_id
    left join pitcher_rolling pr
        on gs.sp_player_id = pr.player_id
        and gs.game_id = pr.game_id
    left join starter_length sl
        on gs.sp_player_id = sl.player_id
        and s.season = sl.season
    left join pitcher_rest prest
        on gs.sp_player_id = prest.player_id
        and gs.game_id = prest.game_id
),

away_sp as (
    select
        gs.game_id,
        gs.sp_player_id                                 as away_sp_id,
        gs.sp_name                                      as away_sp_name,
        gs.sp_throws                                    as away_sp_throws,
        gs.sp_ip_outs                                   as away_sp_ip_outs,
        gs.sp_ip                                        as away_sp_ip,
        gs.sp_er                                        as away_sp_er,
        gs.sp_so                                        as away_sp_so,
        gs.sp_bb                                        as away_sp_bb,
        pr.last5_era                                    as away_sp_last5_era,
        pr.last5_whip                                   as away_sp_last5_whip,
        pr.last5_k_per_9                                as away_sp_last5_k9,
        pr.season_era                                   as away_sp_season_era,
        pr.era_trend                                    as away_sp_era_trend,
        pr.has_rolling_sample                           as away_sp_has_rolling,
        sl.durability_classification                    as away_sp_durability,
        sl.avg_ip_per_start                             as away_sp_avg_ip,
        sl.quality_start_rate                           as away_sp_qs_rate,
        sl.short_outing_rate                            as away_sp_short_outing_rate,
        sl.avg_bullpen_innings_needed                   as away_sp_bp_innings_needed,
        prest.days_rest                                 as away_sp_days_rest,
        prest.rest_classification                       as away_sp_rest_classification,
        prest.is_short_rest                             as away_sp_is_short_rest,
        prest.is_extra_rest                             as away_sp_is_extra_rest,
        prest.is_long_layoff                            as away_sp_is_long_layoff
    from schedule s
    left join game_starters gs
        on s.game_id = gs.game_id
        and s.away_team_id = gs.team_id
    left join pitcher_rolling pr
        on gs.sp_player_id = pr.player_id
        and gs.game_id = pr.game_id
    left join starter_length sl
        on gs.sp_player_id = sl.player_id
        and s.season = sl.season
    left join pitcher_rest prest
        on gs.sp_player_id = prest.player_id
        and gs.game_id = prest.game_id
),

final as (
    select
        -- game identifiers
        s.game_id,
        s.game_date,
        s.season,
        s.first_pitch_et,
        s.home_team_id,
        s.home_team_abbr,
        s.away_team_id,
        s.away_team_abbr,
        s.venue_id,
        s.venue_name,
        s.is_doubleheader,
        s.doubleheader_game_num,

        -- game result (null for upcoming games)
        gr.home_score,
        gr.away_score,
        gr.game_duration_minutes,
        gr.had_rain_delay,
        case when gr.home_score is not null
             then gr.home_score > gr.away_score
             else null
        end                                             as home_won,
        case when gr.home_score is not null
             then gr.home_score + gr.away_score
             else null
        end                                             as total_runs,

        -- odds
        o.home_ml,
        o.away_ml,
        o.home_runline,
        o.home_runline_price,
        o.away_runline,
        o.away_runline_price,
        o.total_line,
        o.over_price,
        o.under_price,
        o.bookmaker,

        -- home SP
        hsp.home_sp_id,
        hsp.home_sp_name,
        hsp.home_sp_throws,
        hsp.home_sp_last5_era,
        hsp.home_sp_last5_whip,
        hsp.home_sp_last5_k9,
        hsp.home_sp_season_era,
        hsp.home_sp_era_trend,
        hsp.home_sp_has_rolling,
        hsp.home_sp_durability,
        hsp.home_sp_avg_ip,
        hsp.home_sp_qs_rate,
        hsp.home_sp_short_outing_rate,
        hsp.home_sp_bp_innings_needed,
        hsp.home_sp_days_rest,
        hsp.home_sp_rest_classification,
        hsp.home_sp_is_short_rest,
        hsp.home_sp_is_extra_rest,
        hsp.home_sp_is_long_layoff,

        -- away SP
        asp.away_sp_id,
        asp.away_sp_name,
        asp.away_sp_throws,
        asp.away_sp_last5_era,
        asp.away_sp_last5_whip,
        asp.away_sp_last5_k9,
        asp.away_sp_season_era,
        asp.away_sp_era_trend,
        asp.away_sp_has_rolling,
        asp.away_sp_durability,
        asp.away_sp_avg_ip,
        asp.away_sp_qs_rate,
        asp.away_sp_short_outing_rate,
        asp.away_sp_bp_innings_needed,
        asp.away_sp_days_rest,
        asp.away_sp_rest_classification,
        asp.away_sp_is_short_rest,
        asp.away_sp_is_extra_rest,
        asp.away_sp_is_long_layoff,

        -- home team rolling
        htr.last10_games                                as home_last10_games,
        htr.last10_wins                                 as home_last10_wins,
        htr.last10_runs_scored_avg                      as home_last10_runs_scored,
        htr.last10_runs_allowed_avg                     as home_last10_runs_allowed,
        htr.last10_ops                                  as home_last10_ops,
        htr.season_win_pct                              as home_season_win_pct,
        htr.season_runs_scored_avg                      as home_season_runs_scored,
        htr.team_streak_flag                            as home_streak_flag,

        -- away team rolling
        atr.last10_games                                as away_last10_games,
        atr.last10_wins                                 as away_last10_wins,
        atr.last10_runs_scored_avg                      as away_last10_runs_scored,
        atr.last10_runs_allowed_avg                     as away_last10_runs_allowed,
        atr.last10_ops                                  as away_last10_ops,
        atr.season_win_pct                              as away_season_win_pct,
        atr.season_runs_scored_avg                      as away_season_runs_scored,
        atr.team_streak_flag                            as away_streak_flag,

        -- home bullpen
        hbp.bp_era_7d                                   as home_bp_era_7d,
        hbp.bp_whip_7d                                  as home_bp_whip_7d,
        hbp.bp_era_signal                               as home_bp_era_signal,
        hbp.bp_era_vs_avg                               as home_bp_era_vs_avg,
        hbp.bp_ip_1d                                    as home_bp_ip_1d,
        hbp.bp_ip_3d                                    as home_bp_ip_3d,
        hbp.bullpen_rested                              as home_bullpen_rested,

        -- away bullpen
        abp.bp_era_7d                                   as away_bp_era_7d,
        abp.bp_whip_7d                                  as away_bp_whip_7d,
        abp.bp_era_signal                               as away_bp_era_signal,
        abp.bp_era_vs_avg                               as away_bp_era_vs_avg,
        abp.bp_ip_1d                                    as away_bp_ip_1d,
        abp.bp_ip_3d                                    as away_bp_ip_3d,
        abp.bullpen_rested                              as away_bullpen_rested,

        -- park
        p.park_type,
        p.hr_park_type,
        p.is_dome,
        p.is_coors,
        p.is_high_altitude,
        p.capped_park_factor_runs,
        p.capped_park_factor_hr,
        p.park_narrative,
        p.elevation_ft,
        p.orientation_degrees,
        p.lf_line,
        p.center,
        p.rf_line,

        -- weather
        w.temp_f,
        w.wind_speed_mph,
        w.wind_direction_label,
        w.wind_relative_to_park,
        w.precip_probability,
        w.condition,
        w.is_outdoor,
        w.wind_signal,
        w.temp_signal,
        w.wind_totals_impact,
        w.temp_totals_impact,
        w.rain_totals_impact,
        w.total_weather_impact,
        w.weather_narrative,

        -- park x temperature interaction (DS audit: amplifies when both present)
        case
            when p.is_dome then 0
            when p.is_coors and w.temp_f >= 75 then 1.0
            when p.park_type = 'hitter_friendly' and w.temp_f >= 85 then 0.50
            when p.park_type = 'hitter_friendly' and w.temp_f >= 75 then 0.25
            when p.park_type = 'pitcher_friendly' and w.temp_f <= 60 then -0.25
            else 0.0
        end                                             as park_temp_interaction_adj,

        -- ump
        ua.hp_ump_id,
        ua.hp_ump_name,
        u.zone_classification                           as ump_zone,
        u.run_environment                               as ump_run_environment,
        u.avg_runs_per_game                             as ump_avg_rpg,
        u.k_per_9                                       as ump_k_per_9,
        u.has_sufficient_sample                         as ump_has_sample,

        -- home context
        hctx.days_rest                                  as home_days_rest,
        hctx.rest_classification                        as home_rest_classification,
        hctx.is_back_to_back                            as home_is_b2b,
        hctx.travel_day                                 as home_travel_day,
        hctx.win_streak_signal                          as home_win_streak_signal,
        hctx.streak_classification                      as home_streak_classification,
        hctx.is_dh_game_2                               as home_is_dh_game2,

        -- away context
        actx.days_rest                                  as away_days_rest,
        actx.rest_classification                        as away_rest_classification,
        actx.is_back_to_back                            as away_is_b2b,
        actx.travel_day                                 as away_travel_day,
        actx.win_streak_signal                          as away_win_streak_signal,
        actx.streak_classification                      as away_streak_classification,

        -- head to head
        h2h.win_pct                                     as h2h_home_win_pct,
        h2h.avg_total_runs                              as h2h_avg_total_runs,
        h2h.run_tendency                                as h2h_run_tendency,
        h2h.series_dominance                            as h2h_dominance,
        h2h.games                                       as h2h_games,

        -- SP x bullpen joint vulnerability flag (DS audit: non-additive compounding effect)
        case
            when (hsp.home_sp_era_trend = 'trending_worse' or hsp.home_sp_durability = 'short_starter')
                 and hbp.bp_era_signal = 'tired'
            then true else false
        end                                             as home_sp_bp_double_vulnerability,

        case
            when (asp.away_sp_era_trend = 'trending_worse' or asp.away_sp_durability = 'short_starter')
                 and abp.bp_era_signal = 'tired'
            then true else false
        end                                             as away_sp_bp_double_vulnerability,

        current_timestamp()                             as inserted_at

    from schedule s
    left join game_results gr
        on s.game_id = gr.game_id
    left join odds o
        on s.game_id = o.game_id
    left join home_sp hsp
        on s.game_id = hsp.game_id
    left join away_sp asp
        on s.game_id = asp.game_id
    left join team_rolling htr
        on s.home_team_id = htr.team_id
        and s.game_id = htr.game_id
    left join team_rolling atr
        on s.away_team_id = atr.team_id
        and s.game_id = atr.game_id
    left join bullpen hbp
        on s.home_team_id = hbp.team_id
        and s.game_id = hbp.game_id
    left join bullpen abp
        on s.away_team_id = abp.team_id
        and s.game_id = abp.game_id
    left join parks p
        on s.venue_id = p.venue_id
        and s.season = p.park_factor_season
    left join weather w
        on s.game_id = w.game_id
    left join ump_assignments ua
        on s.game_id = ua.game_id
    left join umps u
        on ua.hp_ump_id = u.ump_id
    left join context hctx
        on s.home_team_id = hctx.team_id
        and s.game_id = hctx.game_id
    left join context actx
        on s.away_team_id = actx.team_id
        and s.game_id = actx.game_id
    left join h2h
        on s.home_team_id = h2h.team_id
        and s.away_team_id = h2h.opponent_id
        and s.season = h2h.season
)

select * from final