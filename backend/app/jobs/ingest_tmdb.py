import asyncio
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from app.db import SessionLocal
from app.models import Movie
from app.services.tmdb import fetch_trending_movies, normalize_movie

async def ingest_trending():
    data = await fetch_trending_movies()
    saved = 0
    with SessionLocal() as db:
        for item in data:
            payload = normalize_movie(item)
            # upsert by tmdb_id
            existing = db.execute(select(Movie).where(Movie.tmdb_id == payload["tmdb_id"])).scalar_one_or_none()
            if existing:
                for k,v in payload.items():
                    setattr(existing, k, v)
            else:
                db.add(Movie(**payload))
                saved += 1
        try:
            db.commit()
        except IntegrityError:
            db.rollback()
    return {"inserted": saved, "total": len(data)}

def run_sync():
    return asyncio.run(ingest_trending())

if __name__ == "__main__":
    print(run_sync())
