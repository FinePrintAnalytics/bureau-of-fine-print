with game_scores as (
    select * from {{ ref('int_game_scores') }}
),

-- Last 5 matchups this season (pre-aggregated separately)
last5 as (
    select
        team_id,
        opponent_id,
        season,
        sum(win) as last5_wins,
        count(*) as last5_games
    from (
        select
            team_id,
            opponent_id,
            season,
            win,
            row_number() over (
                partition by team_id, opponent_id, season
                order by game_date desc
            ) as rn
        from matchups
    )
    where rn <= 5
    group by 1, 2, 3
),

aggregated as (
    select
        m.team_id,
        m.opponent_id,
        m.season,
        count(*)                                        as games,
        sum(m.win)                                      as wins,
        round(avg(m.team_runs), 2)                      as avg_runs_scored,
        round(avg(m.opp_runs), 2)                       as avg_runs_allowed,
        round(avg(m.total_runs), 2)                     as avg_total_runs,
        countif(m.extra_innings)                        as extra_inning_games,
        l5.last5_wins,
        l5.last5_games
    from matchups m
    left join last5 l5
        on m.team_id = l5.team_id
        and m.opponent_id = l5.opponent_id
        and m.season = l5.season
    group by 1, 2, 3, 9, 10
),
select
    team_a,
    team_b,
    count(*)              as games_played,
    sum(team_a_win)       as team_a_wins,
    sum(1 - team_a_win)   as team_b_wins,
    round(avg(team_a_win), 3) as team_a_win_pct,
    max(game_date)        as last_meeting,
    min(game_date)        as first_meeting
from all_matchups
group by team_a, team_b