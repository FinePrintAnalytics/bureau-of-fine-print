-- mlb_int_starter_length.sql
-- Average innings per start for each starting pitcher.
-- Blends current season with prior season when current sample is thin.
-- One row per pitcher per season.

with pitcher_logs as (
    select * from {{ ref('mlb_stg_game_pitcher_logs') }}
    where is_starter = true
),

aggregated as (
    select
        player_id,
        player_name,
        team_id,
        team_abbr,
        throws,
        season,
        count(distinct game_id)                         as starts,
        sum(ip_outs)                                    as total_ip_outs,
        avg(ip_outs)                                    as avg_ip_outs_per_start,
        min(ip_outs)                                    as min_ip_outs,
        max(ip_outs)                                    as max_ip_outs,
        countif(ip_outs < 15)                           as short_outings,
        countif(ip_outs >= 18)                          as quality_starts,
        countif(ip_outs >= 21)                          as deep_outings
    from pitcher_logs
    group by 1, 2, 3, 4, 5, 6
),

-- prior season stats per pitcher
prior_season as (
    select
        player_id,
        season + 1                                      as next_season,
        starts                                          as prior_starts,
        avg_ip_outs_per_start                           as prior_avg_ip_outs,
        short_outings * 1.0 / nullif(starts, 0)        as prior_short_outing_rate,
        quality_starts * 1.0 / nullif(starts, 0)       as prior_quality_start_rate
    from aggregated
),

-- last 5 starts for recent trend
recent_starts as (
    select
        player_id,
        season,
        avg(ip_outs) over (
            partition by player_id, season
            order by game_date
            rows between 5 preceding and 1 preceding
        )                                               as last5_avg_ip_outs
    from pitcher_logs
    qualify row_number() over (
        partition by player_id, season
        order by game_date desc
    ) = 1
),

blended as (
    select
        a.player_id,
        a.player_name,
        a.team_id,
        a.team_abbr,
        a.throws,
        a.season,
        a.starts,
        p.prior_starts,

        -- blended avg ip outs:
        -- < 3 starts: 20% current / 80% prior (if prior exists), else current only
        -- 3-4 starts: 50% current / 50% prior (if prior exists), else current only  
        -- 5+ starts: 100% current
        case
            when a.starts >= 5
                then a.avg_ip_outs_per_start
            when a.starts >= 3 and p.prior_avg_ip_outs is not null
                then (a.avg_ip_outs_per_start * 0.50) + (p.prior_avg_ip_outs * 0.50)
            when a.starts >= 3
                then a.avg_ip_outs_per_start
            when a.starts >= 1 and p.prior_avg_ip_outs is not null
                then (a.avg_ip_outs_per_start * 0.20) + (p.prior_avg_ip_outs * 0.80)
            else a.avg_ip_outs_per_start
        end                                             as blended_avg_ip_outs,

        -- blended short outing rate
        case
            when a.starts >= 5
                then a.short_outings * 1.0 / nullif(a.starts, 0)
            when a.starts >= 3 and p.prior_short_outing_rate is not null
                then (a.short_outings * 1.0 / nullif(a.starts, 0) * 0.50) + (p.prior_short_outing_rate * 0.50)
            when a.starts >= 1 and p.prior_short_outing_rate is not null
                then (a.short_outings * 1.0 / nullif(a.starts, 0) * 0.20) + (p.prior_short_outing_rate * 0.80)
            else a.short_outings * 1.0 / nullif(a.starts, 0)
        end                                             as blended_short_outing_rate,

        -- blended quality start rate
        case
            when a.starts >= 5
                then a.quality_starts * 1.0 / nullif(a.starts, 0)
            when a.starts >= 3 and p.prior_quality_start_rate is not null
                then (a.quality_starts * 1.0 / nullif(a.starts, 0) * 0.50) + (p.prior_quality_start_rate * 0.50)
            when a.starts >= 1 and p.prior_quality_start_rate is not null
                then (a.quality_starts * 1.0 / nullif(a.starts, 0) * 0.20) + (p.prior_quality_start_rate * 0.80)
            else a.quality_starts * 1.0 / nullif(a.starts, 0)
        end                                             as blended_quality_start_rate,

        a.total_ip_outs,
        a.min_ip_outs,
        a.max_ip_outs,
        a.short_outings,
        a.quality_starts,
        a.deep_outings,
        r.last5_avg_ip_outs

    from aggregated a
    left join prior_season p
        on a.player_id = p.player_id
        and a.season = p.next_season
    left join recent_starts r
        on a.player_id = r.player_id
        and a.season = r.season
),

final as (
    select
        player_id,
        player_name,
        team_id,
        team_abbr,
        throws,
        season,
        starts,
        prior_starts,
        round(total_ip_outs / 3.0, 1)                  as total_ip,
        round(blended_avg_ip_outs / 3.0, 1)            as avg_ip_per_start,
        round(last5_avg_ip_outs / 3.0, 1)              as last5_avg_ip_per_start,
        round(min_ip_outs / 3.0, 1)                    as min_ip,
        round(max_ip_outs / 3.0, 1)                    as max_ip,
        short_outings,
        quality_starts,
        deep_outings,
        round(blended_quality_start_rate, 3)            as quality_start_rate,
        round(blended_short_outing_rate, 3)             as short_outing_rate,
        round(9.0 - blended_avg_ip_outs / 3.0, 1)      as avg_bullpen_innings_needed,

        -- durability now uses blended avg and only requires 1+ start
        case
            when blended_avg_ip_outs >= 18              then 'workhorse'
            when blended_avg_ip_outs >= 15              then 'solid_starter'
            when blended_avg_ip_outs is not null        then 'short_starter'
            else 'insufficient_sample'
        end                                             as durability_classification,

        case when starts >= 1 then true else false end  as has_sample

    from blended
)

select * from final