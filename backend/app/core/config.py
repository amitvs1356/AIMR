import os
class Settings:
    DB_URL = f"postgresql+psycopg2://{os.getenv('POSTGRES_USER')}:{os.getenv('POSTGRES_PASSWORD')}@db:5432/{os.getenv('POSTGRES_DB')}"
    TMDB_API_KEY = os.getenv("TMDB_API_KEY","")
    API_PREFIX = "/api"
settings = Settings()
