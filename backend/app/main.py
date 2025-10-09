from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
import os
from app.api.routes import router

app = FastAPI(title="AI Movie Platform")

BASE_DIR = os.path.dirname(os.path.abspath(__file__))   # /app/app
STATIC_DIR = os.path.join(BASE_DIR, "static")
os.makedirs(STATIC_DIR, exist_ok=True)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

class Settings:
    API_PREFIX = "/api"
settings = Settings()
app.include_router(router, prefix=settings.API_PREFIX)
