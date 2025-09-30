from pydantic import BaseModel
from typing import Optional
class MovieOut(BaseModel):
    id: int
    tmdb_id: int
    title: str
    original_title: Optional[str] = None
    language: Optional[str] = None
    overview: Optional[str] = None
    release_date: Optional[str] = None
    poster_path: Optional[str] = None
    backdrop_path: Optional[str] = None
    popularity: Optional[float] = None
    vote_average: Optional[float] = None
    vote_count: Optional[int] = None
    class Config: from_attributes = True
