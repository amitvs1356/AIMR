from fastapi import APIRouter, HTTPException, Depends, Query
from sqlalchemy import text
from sqlalchemy.orm import Session
from app.db import SessionLocal
from app.schemas import MovieOut
from app.core.config import settings
import httpx, os

router = APIRouter()

def get_db():
    db = SessionLocal()
    try: yield db
    finally: db.close()

@router.get("/health")
def health():
    return {"ok": True}

@router.get("/movies", response_model=list[MovieOut])
def list_movies(limit: int = Query(20, le=100), offset: int = 0, db: Session = Depends(get_db)):
    # tolerant: if popularity/vote_x not present, still select core columns
    sql = text("""
        SELECT id, tmdb_id, title, original_title, language, overview, release_date,
               poster_path, backdrop_path,
               COALESCE(popularity,0)::float AS popularity,
               COALESCE(vote_average,0)::float AS vote_average,
               COALESCE(vote_count,0)::int AS vote_count
        FROM movies
        ORDER BY COALESCE(popularity,0) DESC
        LIMIT :limit OFFSET :offset
    """)
    rows = db.execute(sql, {"limit": limit, "offset": offset}).mappings().all()
    return [MovieOut(**dict(r)) for r in rows]

@router.post("/ingest/tmdb/trending")
def ingest_trending(db: Session = Depends(get_db)):
    token = settings.TMDB_API_KEY
    if not token or token.startswith("PUT_YOUR_"):
        raise HTTPException(500,"TMDB token missing/invalid in .env")
    headers = {"Authorization": f"Bearer {token}"}
    url = "https://api.themoviedb.org/3/trending/movie/day?language=en-US"
    r = httpx.get(url, headers=headers, timeout=30)
    if r.status_code != 200:
        raise HTTPException(500, f"TMDb error {r.status_code}: {r.text[:200]}")
    data = r.json().get("results",[])
    # insert minimal columns + upserts
    for m in data[:50]:
        db.execute(text("""
            INSERT INTO movies (tmdb_id, title, original_title, language, overview, release_date,
                                poster_path, backdrop_path, imdb_id, is_series, slug, runtime,
                                budget, revenue, popularity, vote_average, vote_count)
            VALUES (:tmdb_id, :title, :original_title, :language, :overview, :release_date,
                    :poster_path, :backdrop_path, NULL, false, NULL, NULL,
                    NULL, NULL, :popularity, :vote_average, :vote_count)
            ON CONFLICT (tmdb_id) DO UPDATE SET
                title = EXCLUDED.title,
                original_title = EXCLUDED.original_title,
                language = EXCLUDED.language,
                overview = EXCLUDED.overview,
                release_date = EXCLUDED.release_date,
                poster_path = EXCLUDED.poster_path,
                backdrop_path = EXCLUDED.backdrop_path,
                popularity = EXCLUDED.popularity,
                vote_average = EXCLUDED.vote_average,
                vote_count = EXCLUDED.vote_count
        """), {
            "tmdb_id": m.get("id"),
            "title": m.get("title") or m.get("name") or "",
            "original_title": m.get("original_title"),
            "language": m.get("original_language"),
            "overview": m.get("overview"),
            "release_date": m.get("release_date"),
            "poster_path": m.get("poster_path"),
            "backdrop_path": m.get("backdrop_path"),
            "popularity": m.get("popularity"),
            "vote_average": m.get("vote_average"),
            "vote_count": m.get("vote_count"),
        })
    db.commit()
    return {"ok": True, "count": len(data)}
