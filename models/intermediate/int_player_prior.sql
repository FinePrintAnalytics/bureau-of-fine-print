WITH current_season AS (
    SELECT MAX(season) AS season
    FROM {{ ref('stg_games') }}
),

prior_season AS (
    SELECT MAX(season) AS season
    FROM {{ ref('stg_games') }}
    WHERE season < (SELECT season FROM current_season)
),

prior_rows AS (
    SELECT
        INITCAP(`project-71e6f4ed-bf24-4c0f-bb0.marts.normalize_player_name`(ps.player_name)) AS player_key,
        ps.minutes_played,
        ps.points
          + (ps.rebounds * 1.2)
          + (ps.assists  * 1.5)
          + (ps.steals   * 3.0)
          + (ps.blocks   * 2.5) AS impact
    FROM {{ ref('stg_player_game_stats') }} ps
    INNER JOIN {{ ref('stg_games') }} g
        ON ps.game_id = g.game_id
    WHERE g.season = (SELECT season FROM prior_season)
      AND ps.minutes_played > 0
),

prior_totals AS (
    SELECT
        player_key,
        SUM(minutes_played) AS prior_minutes,
        SUM(impact)         AS prior_impact_total
    FROM prior_rows
    GROUP BY player_key
),

league_rate AS (
    SELECT SUM(prior_impact_total) / SUM(prior_minutes) AS lg_rate
    FROM prior_totals
)

SELECT
    pt.player_key,
    pt.prior_minutes,
    (pt.prior_impact_total + 600 * lr.lg_rate) / (pt.prior_minutes + 600) AS prior_rate,
    lr.lg_rate
FROM prior_totals pt
CROSS JOIN league_rate lr