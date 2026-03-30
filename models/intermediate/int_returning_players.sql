<<<<<<< HEAD
WITH current_season AS (
    SELECT MAX(season) AS season
    FROM {{ ref('stg_games') }}
),

recent_team AS (
    SELECT
        ps.player_name,
        ps.team_id,
        MAX(g.game_date) AS last_game_date_for_team
    FROM {{ ref('stg_player_game_stats') }} ps
    INNER JOIN {{ ref('stg_games') }} g
        ON ps.game_id = g.game_id
    CROSS JOIN current_season cs
    WHERE g.season = cs.season
    GROUP BY ps.player_name, ps.team_id
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY ps.player_name
        ORDER BY MAX(g.game_date) DESC
    ) = 1
),

last_game AS (
    SELECT
        rt.player_name,
        rt.team_id,
        rt.last_game_date_for_team                                                          AS last_game_date,
        DATE_DIFF(DATE(CURRENT_TIMESTAMP(), 'America/New_York'), rt.last_game_date_for_team, DAY) AS days_since_last_game,
        ps.pts_season_avg,
        ps.reb_season_avg,
        ps.ast_season_avg
    FROM recent_team rt
    INNER JOIN {{ ref('int_player_rolling_averages') }} ps
        ON rt.player_name = ps.player_name
        AND rt.team_id = ps.team_id
    INNER JOIN {{ ref('stg_games') }} g
        ON ps.game_id = g.game_id
        AND g.game_date = rt.last_game_date_for_team
    WHERE ps.pts_season_avg >= 15
),

injured_today AS (
    SELECT
        team_id,
        LOWER(REGEXP_REPLACE(player_name, '[^a-zA-Z ]', '')) AS player_name_normalized,
        status
    FROM {{ ref('stg_injuries') }}
    WHERE game_date = DATE(CURRENT_TIMESTAMP(), 'America/New_York')
    AND status IN ('Out', 'Doubtful')
),

tonights_teams AS (
    SELECT DISTINCT home_team_id AS team_id
    FROM {{ ref('stg_games') }}
    WHERE game_date = DATE(CURRENT_TIMESTAMP(), 'America/New_York')
    UNION DISTINCT
    SELECT DISTINCT away_team_id
    FROM {{ ref('stg_games') }}
    WHERE game_date = DATE(CURRENT_TIMESTAMP(), 'America/New_York')
),

team_last10 AS (
    SELECT team_id, game_date
    FROM (
        SELECT home_team_id AS team_id, g.game_date,
               ROW_NUMBER() OVER (PARTITION BY home_team_id ORDER BY g.game_date DESC) AS rn
        FROM {{ ref('stg_games') }} g
        INNER JOIN {{ ref('stg_game_results') }} gr ON g.game_id = gr.game_id
        CROSS JOIN current_season cs
        WHERE g.season = cs.season
        UNION ALL
        SELECT away_team_id AS team_id, g.game_date,
               ROW_NUMBER() OVER (PARTITION BY away_team_id ORDER BY g.game_date DESC) AS rn
        FROM {{ ref('stg_games') }} g
        INNER JOIN {{ ref('stg_game_results') }} gr ON g.game_id = gr.game_id
        CROSS JOIN current_season cs
        WHERE g.season = cs.season
    )
    WHERE rn <= 10
),

games_missed_recent AS (
    SELECT
        pss.player_name,
        pss.team_id,
        COUNT(DISTINCT t.game_date) AS games_missed_last10
    FROM last_game pss
    INNER JOIN team_last10 t
        ON pss.team_id = t.team_id
        AND t.game_date > pss.last_game_date
    GROUP BY pss.player_name, pss.team_id
)

SELECT
    lg.player_name,
    lg.team_id,
    lg.last_game_date,
    lg.days_since_last_game,
    lg.pts_season_avg,
    lg.reb_season_avg,
    lg.ast_season_avg,
    CASE
        WHEN lg.days_since_last_game >= 30 THEN 'LONG_ABSENCE'
        WHEN lg.days_since_last_game >= 15 THEN 'MEDIUM_ABSENCE'
        WHEN lg.days_since_last_game >= 7  THEN 'SHORT_ABSENCE'
        ELSE NULL
    END                                                         AS absence_tier,
    ROUND((lg.pts_season_avg - 15) / 10, 2)                   AS impact_score
FROM last_game lg
INNER JOIN tonights_teams tt
    ON lg.team_id = tt.team_id
LEFT JOIN games_missed_recent gmr
    ON lg.player_name = gmr.player_name
    AND lg.team_id = gmr.team_id
WHERE lg.days_since_last_game >= 7
AND lg.days_since_last_game <= 45
AND COALESCE(gmr.games_missed_last10, 0) < 10
AND NOT EXISTS (
    SELECT 1
    FROM injured_today i
    WHERE i.team_id = lg.team_id
    AND i.player_name_normalized = LOWER(REGEXP_REPLACE(lg.player_name, '[^a-zA-Z ]', ''))
)
ORDER BY lg.days_since_last_game DESC
=======
WITH current_season AS (
    SELECT MAX(season) AS season
    FROM {{ ref('stg_games') }}
),

recent_team AS (
    SELECT
        ps.player_name,
        ps.team_id,
        MAX(g.game_date) AS last_game_date_for_team
    FROM {{ ref('stg_player_game_stats') }} ps
    INNER JOIN {{ ref('stg_games') }} g
        ON ps.game_id = g.game_id
    CROSS JOIN current_season cs
    WHERE g.season = cs.season
    GROUP BY ps.player_name, ps.team_id
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY ps.player_name
        ORDER BY MAX(g.game_date) DESC
    ) = 1
),

last_game AS (
    SELECT
        rt.player_name,
        rt.team_id,
        rt.last_game_date_for_team                                                      AS last_game_date,
        DATE_DIFF(DATE(CURRENT_TIMESTAMP(), 'America/New_York'), rt.last_game_date_for_team, DAY) AS days_since_last_game,
        ps.pts_season_avg,
        ps.reb_season_avg,
        ps.ast_season_avg
    FROM recent_team rt
    INNER JOIN {{ ref('int_player_rolling_averages') }} ps
        ON rt.player_name = ps.player_name
        AND rt.team_id = ps.team_id
    INNER JOIN {{ ref('stg_games') }} g
        ON ps.game_id = g.game_id
        AND g.game_date = rt.last_game_date_for_team
    WHERE ps.pts_season_avg >= 15
),

injured_today AS (
    SELECT
        team_id,
        LOWER(REGEXP_REPLACE(player_name, '[^a-zA-Z ]', '')) AS player_name_normalized,
        status
    FROM {{ ref('stg_injuries') }}
    WHERE game_date = DATE(CURRENT_TIMESTAMP(), 'America/New_York')
    AND status IN ('Out', 'Doubtful')
),

tonights_teams AS (
    SELECT DISTINCT home_team_id AS team_id
    FROM {{ ref('stg_games') }}
    WHERE game_date = DATE(CURRENT_TIMESTAMP(), 'America/New_York')
    UNION DISTINCT
    SELECT DISTINCT away_team_id
    FROM {{ ref('stg_games') }}
    WHERE game_date = DATE(CURRENT_TIMESTAMP(), 'America/New_York')
)

SELECT
    lg.player_name,
    lg.team_id,
    lg.last_game_date,
    lg.days_since_last_game,
    lg.pts_season_avg,
    lg.reb_season_avg,
    lg.ast_season_avg,
    CASE
        WHEN lg.days_since_last_game >= 30 THEN 'LONG_ABSENCE'
        WHEN lg.days_since_last_game >= 15 THEN 'MEDIUM_ABSENCE'
        WHEN lg.days_since_last_game >= 7  THEN 'SHORT_ABSENCE'
        ELSE NULL
    END                                                         AS absence_tier,
    ROUND((lg.pts_season_avg - 15) / 10, 2)                   AS impact_score
FROM last_game lg
INNER JOIN tonights_teams tt
    ON lg.team_id = tt.team_id
WHERE lg.days_since_last_game >= 7
AND NOT EXISTS (
    SELECT 1
    FROM injured_today i
    WHERE i.team_id = lg.team_id
    AND i.player_name_normalized = LOWER(REGEXP_REPLACE(lg.player_name, '[^a-zA-Z ]', ''))
)
AND lg.days_since_last_game <= 45
ORDER BY lg.days_since_last_game DESC
>>>>>>> 25a037b6dede0056e1e9f2cd45a25b99723a7594
