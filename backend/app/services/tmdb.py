import os, httpx, datetime

TMDB_API_KEY = os.getenv("TMDB_API_KEY")

BASE = "https://api.themoviedb.org/3"
HEADERS = {"Authorization": f"Bearer {TMDB_API_KEY}"} if TMDB_API_KEY else {}
TIMEOUT = 30.0

async def fetch_trending_movies():
    if not TMDB_API_KEY:
        raise RuntimeError("TMDB_API_KEY not set")
    url = f"{BASE}/trending/movie/week"
    async with httpx.AsyncClient(timeout=TIMEOUT, headers=HEADERS) as client:
        r = await client.get(url, params={"language":"en-US"})
        r.raise_for_status()
        return r.json().get("results", [])

def normalize_movie(m: dict):
    rd = m.get("release_date") or None
    if rd:
        try:
            rd = datetime.date.fromisoformat(rd)
        except Exception:
            rd = None
    return {
        "tmdb_id": m.get("id"),
        "title": m.get("title") or m.get("name") or "Untitled",
        "original_title": m.get("original_title"),
        "language": m.get("original_language"),
        "release_date": rd,
        "overview": m.get("overview"),
        "poster_path": m.get("poster_path"),
        "backdrop_path": m.get("backdrop_path"),
        "popularity": m.get("popularity"),
        "vote_average": m.get("vote_average"),
        "vote_count": m.get("vote_count"),
    }
