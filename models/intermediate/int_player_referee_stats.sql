WITH ref_games AS (
    SELECT game_id, referee_1 AS referee_id FROM `project-71e6f4ed-bf24-4c0f-bb0.staging.stg_referee_assignments` WHERE referee_1 IS NOT NULL
    UNION ALL
    SELECT game_id, referee_2 AS referee_id FROM `project-71e6f4ed-bf24-4c0f-bb0.staging.stg_referee_assignments` WHERE referee_2 IS NOT NULL
    UNION ALL
    SELECT game_id, referee_3 AS referee_id FROM `project-71e6f4ed-bf24-4c0f-bb0.staging.stg_referee_assignments` WHERE referee_3 IS NOT NULL
),

current_season_games AS (
    SELECT game_id
    FROM `project-71e6f4ed-bf24-4c0f-bb0.staging.stg_games`
    WHERE season = (SELECT MAX(season) FROM `project-71e6f4ed-bf24-4c0f-bb0.staging.stg_games`)
),

player_ref_stats AS (
    SELECT
        p.player_name,
        p.team_id,
        r.referee_id,
        COUNT(*)                    AS games_with_referee,
        ROUND(AVG(p.points), 1)     AS avg_points,
        ROUND(AVG(p.plus_minus), 1) AS avg_plus_minus
    FROM `project-71e6f4ed-bf24-4c0f-bb0.staging.stg_player_game_stats` p
    INNER JOIN current_season_games csg ON p.game_id = csg.game_id
    INNER JOIN ref_games r ON p.game_id = r.game_id
    WHERE p.minutes_played > 0
        AND p.minutes_played IS NOT NULL
    GROUP BY p.player_name, p.team_id, r.referee_id
)

SELECT
    prs.player_name,
    prs.team_id,
    dr.full_name                                        AS referee_name,
    prs.games_with_referee,
    prs.avg_points                                      AS avg_pts_with_ref,
    ps.pts_season_avg,
    ROUND(prs.avg_points - ps.pts_season_avg, 1)       AS pts_diff_vs_season_avg,
    prs.avg_plus_minus
FROM player_ref_stats prs
JOIN `project-71e6f4ed-bf24-4c0f-bb0.marts.mart_player_summary` ps
    ON prs.player_name = ps.player_name
    AND prs.team_id = ps.team_id
JOIN `project-71e6f4ed-bf24-4c0f-bb0.seeds.dim_referees` dr
    ON CAST(prs.referee_id AS INT64) = dr.referee_id
WHERE prs.games_with_referee >= 3
    AND ps.pts_season_avg >= 15
    AND ABS(prs.avg_points - ps.pts_season_avg) >= 3

ORDER BY pts_diff_vs_season_avg DESC
