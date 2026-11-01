WITH current_season AS (
    SELECT MAX(season) AS season
    FROM {{ ref('stg_games') }}
),

team_games AS (
    SELECT team_id, COUNT(DISTINCT game_id) AS team_games
    FROM (
        SELECT g.home_team_id AS team_id, g.game_id
        FROM {{ ref('stg_games') }} g
        INNER JOIN {{ ref('stg_game_results') }} gr ON g.game_id = gr.game_id
        WHERE g.season = (SELECT season FROM current_season)
        UNION ALL
        SELECT g.away_team_id AS team_id, g.game_id
        FROM {{ ref('stg_games') }} g
        INNER JOIN {{ ref('stg_game_results') }} gr ON g.game_id = gr.game_id
        WHERE g.season = (SELECT season FROM current_season)
    )
    GROUP BY team_id
),

current_rows AS (
    SELECT
        INITCAP(`project-71e6f4ed-bf24-4c0f-bb0.marts.normalize_player_name`(ps.player_name)) AS player_key,
        ps.team_id,
        g.game_date,
        ps.game_id,
        ps.minutes_played,
        ps.points
          + (ps.rebounds * 1.2)
          + (ps.assists  * 1.5)
          + (ps.steals   * 3.0)
          + (ps.blocks   * 2.5) AS impact
    FROM {{ ref('stg_player_game_stats') }} ps
    INNER JOIN {{ ref('stg_games') }} g
        ON ps.game_id = g.game_id
    WHERE g.season = (SELECT season FROM current_season)
      AND ps.minutes_played > 0
),

-- a player belongs to the team he most recently played for
latest_team AS (
    SELECT player_key, team_id
    FROM current_rows
    WHERE TRUE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY player_key ORDER BY game_date DESC) = 1
),

current_player AS (
    SELECT
        cr.player_key,
        cr.team_id,
        COUNT(DISTINCT cr.game_id) AS cur_games,
        SUM(cr.minutes_played)     AS cur_minutes,
        SUM(cr.impact)             AS cur_impact_total
    FROM current_rows cr
    INNER JOIN latest_team lt
        ON cr.player_key = lt.player_key AND cr.team_id = lt.team_id
    GROUP BY cr.player_key, cr.team_id
),

lg AS (
    SELECT MAX(lg_rate) AS lg_rate
    FROM {{ ref('int_player_prior') }}
),

player_blend AS (
    SELECT
        cp.team_id,
        cp.player_key,
        cp.cur_minutes / cp.cur_games                       AS cur_mpg,
        cp.cur_impact_total / cp.cur_minutes                AS cur_rate,
        COALESCE(pp.prior_rate, lg.lg_rate)                 AS prior_rate,
        pp.player_key IS NOT NULL                           AS has_prior,
        LEAST(1.0, tg.team_games / 20.0)                    AS w,
        tg.team_games
    FROM current_player cp
    INNER JOIN team_games tg ON cp.team_id = tg.team_id
    CROSS JOIN lg
    LEFT JOIN {{ ref('int_player_prior') }} pp
        ON cp.player_key = pp.player_key
),

team_rating AS (
    SELECT
        team_id,
        MAX(team_games)                                                       AS team_games,
        MAX(w)                                                                AS w,
        COUNT(*)                                                              AS players,
        COUNTIF(NOT has_prior)                                                AS players_without_prior,
        ROUND(SAFE_DIVIDE(SUM(IF(has_prior, 0, cur_mpg)), SUM(cur_mpg)), 3)   AS minutes_share_without_prior,
        36 * SAFE_DIVIDE(SUM(cur_mpg * (w * cur_rate + (1 - w) * prior_rate)), SUM(cur_mpg)) AS blended_rating,
        36 * SAFE_DIVIDE(SUM(cur_mpg * prior_rate), SUM(cur_mpg))             AS prior_rating,
        36 * SAFE_DIVIDE(SUM(cur_mpg * cur_rate),   SUM(cur_mpg))             AS current_rating
    FROM player_blend
    GROUP BY team_id
)

SELECT
    *,
    (blended_rating - AVG(blended_rating) OVER ()) / NULLIF(STDDEV(blended_rating) OVER (), 0) AS strength_z,
    (prior_rating   - AVG(prior_rating)   OVER ()) / NULLIF(STDDEV(prior_rating)   OVER (), 0) AS prior_z
FROM team_rating