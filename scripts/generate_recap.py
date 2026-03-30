"""
NBA Fine Print — Weekly Recap Generator
Pulls last week's qualifying picks from mart_model_tracker, shows weekly + season record,
and detailed pick-by-pick results. Posts to both Substack publications every Monday.

Usage:
    python generate_recap.py
    python generate_recap.py --date 2026-03-09   # override week ending date (Sunday)
    python generate_recap.py --debug             # skip Substack, print output only
"""

import argparse
import os
from datetime import date, timedelta

from google.cloud import bigquery, secretmanager
from substack import Api
from substack.post import Post as SubstackPost


# ── Config ────────────────────────────────────────────────────────────────────
PROJECT_ID         = "project-71e6f4ed-bf24-4c0f-bb0"
DATASET            = "marts"
TRACKER_TABLE      = f"{PROJECT_ID}.{DATASET}.mart_model_tracker"
SUBSTACK_URL       = "https://nbafineprint.substack.com"
PICKS_SUBSTACK_URL = "https://nbafineprintpicks.substack.com"
USER_ID            = 464007441
SEPARATOR          = "· · · · · · · · · · · · · · · · · · · · · · · · · · · · · ·"


# ── Secret Manager ────────────────────────────────────────────────────────────
def get_secret(secret_id: str) -> str:
    env_map = {"substack-session-cookie": "SUBSTACK_SESSION_COOKIE"}
    env_var = env_map.get(secret_id)
    if env_var and os.environ.get(env_var):
        return os.environ[env_var]
    client = secretmanager.SecretManagerServiceClient()
    name   = f"projects/{PROJECT_ID}/secrets/{secret_id}/versions/latest"
    return client.access_secret_version(request={"name": name}).payload.data.decode("UTF-8").strip()


# ── Date helpers ──────────────────────────────────────────────────────────────
def get_week_range(override_date: str = None):
    today  = date.fromisoformat(override_date) if override_date else date.today()
    sunday = today - timedelta(days=(today.weekday() + 1) % 7)
    monday = sunday - timedelta(days=6)
    return monday, sunday


# ── Fetch picks from BQ ───────────────────────────────────────────────────────
def fetch_weekly_picks(monday: date, sunday: date, bq_client) -> dict:
    week_start = monday.isoformat()
    week_end   = sunday.isoformat()

    week_spread_query = f"""
        WITH latest AS (
            SELECT *, ROW_NUMBER() OVER (
                PARTITION BY game_date, home_team_id, away_team_id
                ORDER BY scored_at DESC
            ) AS rn
            FROM `{TRACKER_TABLE}`
            WHERE game_date BETWEEN '{week_start}' AND '{week_end}'
        )
        SELECT * EXCEPT (rn) FROM latest
        WHERE rn = 1
          AND divergence_strength = 'STRONG'
          AND signal_strength IN ('STRONG', 'MEDIUM')
          AND divergence_correct IS NOT NULL
        ORDER BY game_date ASC, home_team_id ASC
    """

    week_ou_query = f"""
        WITH latest AS (
            SELECT *, ROW_NUMBER() OVER (
                PARTITION BY game_date, home_team_id, away_team_id
                ORDER BY scored_at DESC
            ) AS rn
            FROM `{TRACKER_TABLE}`
            WHERE game_date BETWEEN '{week_start}' AND '{week_end}'
        )
        SELECT * EXCEPT (rn) FROM latest
        WHERE rn = 1
          AND ou_signal_strength = 'STRONG'
          AND model_ou_correct IS NOT NULL
        ORDER BY game_date ASC, home_team_id ASC
    """

    season_spread_query = f"""
        WITH latest AS (
            SELECT *, ROW_NUMBER() OVER (
                PARTITION BY game_date, home_team_id, away_team_id
                ORDER BY scored_at DESC
            ) AS rn
            FROM `{TRACKER_TABLE}`
        )
        SELECT
            COUNTIF(divergence_correct = TRUE) AS correct,
            COUNT(*) AS total
        FROM latest
        WHERE rn = 1
          AND divergence_strength = 'STRONG'
          AND signal_strength IN ('STRONG', 'MEDIUM')
          AND divergence_correct IS NOT NULL
    """

    season_ou_query = f"""
        WITH latest AS (
            SELECT *, ROW_NUMBER() OVER (
                PARTITION BY game_date, home_team_id, away_team_id
                ORDER BY scored_at DESC
            ) AS rn
            FROM `{TRACKER_TABLE}`
        )
        SELECT
            COUNTIF(model_ou_correct = TRUE) AS correct,
            COUNT(*) AS total
        FROM latest
        WHERE rn = 1
          AND ou_signal_strength = 'STRONG'
          AND model_ou_correct IS NOT NULL
    """

    week_spread   = [dict(r) for r in bq_client.query(week_spread_query).result()]
    week_ou       = [dict(r) for r in bq_client.query(week_ou_query).result()]
    season_spread = list(bq_client.query(season_spread_query).result())[0]
    season_ou     = list(bq_client.query(season_ou_query).result())[0]

    return {
        "week_spread"          : week_spread,
        "week_ou"              : week_ou,
        "season_spread_correct": season_spread["correct"],
        "season_spread_total"  : season_spread["total"],
        "season_ou_correct"    : season_ou["correct"],
        "season_ou_total"      : season_ou["total"],
    }


# ── Format helpers ────────────────────────────────────────────────────────────
def result_label(correct) -> str:
    if correct is True:  return "✅ WIN"
    if correct is False: return "❌ LOSS"
    return "➖ PUSH"

def record_str(correct: int, total: int) -> str:
    losses = total - correct
    pct    = round(correct * 100 / total, 1) if total > 0 else 0.0
    return f"{correct}-{losses} ({pct}%)"

def spread_side(row) -> str:
    mvm = row.get("model_vs_market") or 0
    return f"{row['home_team_id']} (HOME)" if mvm >= 0.10 else f"{row['away_team_id']} (AWAY)"

def ou_side(row) -> str:
    mvl = row.get("model_vs_line") or 0
    return f"OVER (~{abs(round(mvl, 1))} pts)" if mvl >= 5 else f"UNDER (~{abs(round(mvl, 1))} pts)"


# ── Build post content ────────────────────────────────────────────────────────
def _build_recap_post(post, data, monday, sunday, include_cta):
    week_spread         = data["week_spread"]
    week_ou             = data["week_ou"]
    week_spread_correct = sum(1 for g in week_spread if g.get("divergence_correct") is True)
    week_ou_correct     = sum(1 for g in week_ou if g.get("model_ou_correct") is True)
    date_range          = f"{monday.strftime('%B %d')} - {sunday.strftime('%B %d, %Y')}"

    # Header
    post.add({"type": "paragraph", "content": [{"content": f"Week of {date_range}", "marks": [{"type": "strong"}]}]})
    post.add({"type": "paragraph", "content": SEPARATOR})

    # Weekly record
    post.add({"type": "paragraph", "content": [{"content": "THIS WEEK", "marks": [{"type": "strong"}]}]})
    if week_spread:
        post.add({"type": "paragraph", "content": f"Spread: {record_str(week_spread_correct, len(week_spread))}"})
    else:
        post.add({"type": "paragraph", "content": "Spread: No qualifying picks this week"})
    if week_ou:
        post.add({"type": "paragraph", "content": f"O/U: {record_str(week_ou_correct, len(week_ou))}"})
    else:
        post.add({"type": "paragraph", "content": "O/U: No qualifying picks this week"})
    post.add({"type": "paragraph", "content": SEPARATOR})

    # Season record
    post.add({"type": "paragraph", "content": [{"content": "SEASON RECORD", "marks": [{"type": "strong"}]}]})
    post.add({"type": "paragraph", "content": f"Spread: {record_str(data['season_spread_correct'], data['season_spread_total'])}"})
    post.add({"type": "paragraph", "content": f"O/U: {record_str(data['season_ou_correct'], data['season_ou_total'])}"})
    post.add({"type": "paragraph", "content": SEPARATOR})

    # Spread picks detail
    if week_spread:
        post.add({"type": "paragraph", "content": [{"content": "SPREAD PICKS — THIS WEEK", "marks": [{"type": "strong"}]}]})
        for g in week_spread:
            game_date  = str(g.get("game_date", ""))[:10]
            spread     = g.get("spread_home", "N/A")
            spread_str = f"+{spread}" if isinstance(spread, (int, float)) and spread > 0 else str(spread)
            side       = spread_side(g)
            result     = result_label(g.get("divergence_correct"))
            actual     = g.get("actual_margin")

            post.add({"type": "paragraph", "content": [{"content": f"{g['away_team_id']} @ {g['home_team_id']} — {game_date}", "marks": [{"type": "strong"}]}]})
            post.add({"type": "paragraph", "content": f"Line: {g['home_team_id']} {spread_str} | Pick: {side} | Result: {result}"})
            if actual is not None:
                post.add({"type": "paragraph", "content": f"Final margin: {actual:+}"})
            post.add({"type": "paragraph", "content": SEPARATOR})

    # O/U picks detail
    if week_ou:
        post.add({"type": "paragraph", "content": [{"content": "O/U PICKS — THIS WEEK", "marks": [{"type": "strong"}]}]})
        for g in week_ou:
            game_date = str(g.get("game_date", ""))[:10]
            total     = g.get("over_under", "N/A")
            side      = ou_side(g)
            result    = result_label(g.get("model_ou_correct"))
            actual    = g.get("actual_total")

            post.add({"type": "paragraph", "content": [{"content": f"{g['away_team_id']} @ {g['home_team_id']} — {game_date}", "marks": [{"type": "strong"}]}]})
            post.add({"type": "paragraph", "content": f"Total: {total} | Pick: {side} | Result: {result}"})
            if actual is not None:
                post.add({"type": "paragraph", "content": f"Final total: {actual}"})
            post.add({"type": "paragraph", "content": SEPARATOR})

    # CTA (insights only)
    if include_cta:
        post.add({"type": "paragraph", "content": "Get the picks before every game → nbafineprintpicks.substack.com"})


# ── Publish — mirrors _publish_post from generate_previews.py exactly ────────
def _publish_recap(api, user_id, title, subtitle, data, monday, sunday, include_cta):
    post = SubstackPost(
        title=title,
        subtitle=subtitle,
        user_id=user_id,
        audience="everyone",
        write_comment_permissions="everyone",
    )
    _build_recap_post(post, data, monday, sunday, include_cta)

    draft    = api.post_draft(post.get_draft())
    draft_id = draft.get("id")
    print(f"Draft created — id={draft_id}, audience=everyone")
    api.prepublish_draft(draft_id)
    api.publish_draft(draft_id)
    url = draft.get("canonical_url", "")
    print(f"Published: {url}")
    return url


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--date",  default=None, help="Override Sunday end date (YYYY-MM-DD)")
    parser.add_argument("--debug", action="store_true", help="Skip Substack, print summary only")
    args = parser.parse_args()

    monday, sunday = get_week_range(args.date)
    print(f"Recap for week: {monday} - {sunday}")

    bq_client = bigquery.Client(project=PROJECT_ID)
    data      = fetch_weekly_picks(monday, sunday, bq_client)

    print(f"Week spread picks: {len(data['week_spread'])}")
    print(f"Week O/U picks: {len(data['week_ou'])}")
    print(f"Season spread: {data['season_spread_correct']}/{data['season_spread_total']}")
    print(f"Season O/U: {data['season_ou_correct']}/{data['season_ou_total']}")

    if not data["week_spread"] and not data["week_ou"]:
        print("No qualifying picks this week — skipping post.")
        return

    if args.debug:
        print("DEBUG mode — skipping Substack.")
        return

    week_label = f"{monday.strftime('%b %d')} - {sunday.strftime('%b %d')}"
    title      = f"NBA Fine Print — Weekly Recap | {week_label}"
    subtitle   = "Weekly record + full pick-by-pick results"
    cookie     = get_secret("substack-session-cookie")

    # Post to insights
    try:
        api     = Api(cookies_string=f"substack.sid={cookie}", publication_url=SUBSTACK_URL)
        user_id = api.get_user_id()
        print(f"Insights auth OK — user_id={user_id}")
        _publish_recap(api, user_id, title, subtitle, data, monday, sunday, include_cta=True)
    except Exception as e:
        print(f"Insights publish failed: {e}")

    # Post to picks
    try:
        api     = Api(cookies_string=f"substack.sid={cookie}", publication_url=PICKS_SUBSTACK_URL)
        user_id = api.get_user_id()
        print(f"Picks auth OK — user_id={user_id}")
        _publish_recap(api, user_id, title, subtitle, data, monday, sunday, include_cta=False)
    except Exception as e:
        print(f"Picks publish failed: {e}")

    print("Done.")


if __name__ == "__main__":
    main()