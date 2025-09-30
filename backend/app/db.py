from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from app.core.config import settings
engine = create_engine(settings.DB_URL, pool_pre_ping=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)
