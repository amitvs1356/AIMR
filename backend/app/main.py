from fastapi import FastAPI
from app.api.routes import router
from app.core.config import settings
app = FastAPI(title="AI Movie Platform")
app.include_router(router, prefix=settings.API_PREFIX)
