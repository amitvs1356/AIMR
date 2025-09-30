"""movies + related tables"""
from alembic import op
import sqlalchemy as sa

revision = '0002_movies'
down_revision = '0001_init'
branch_labels = None
depends_on = None

def upgrade():
    op.create_table(
        'movies',
        sa.Column('id', sa.Integer, primary_key=True),
        sa.Column('tmdb_id', sa.Integer, nullable=False),
        sa.Column('slug', sa.String(255)),
        sa.Column('title', sa.String(255), nullable=False),
        sa.Column('original_title', sa.String(255)),
        sa.Column('language', sa.String(16)),
        sa.Column('overview', sa.Text),
        sa.Column('release_date', sa.Date),
        sa.Column('runtime', sa.Integer),
        sa.Column('budget', sa.BigInteger),
        sa.Column('revenue', sa.BigInteger),
        sa.Column('poster_path', sa.String(255)),
        sa.Column('backdrop_path', sa.String(255)),
        sa.Column('imdb_id', sa.String(64)),
        sa.Column('is_series', sa.Boolean, server_default=sa.text('false')),
        sa.UniqueConstraint('tmdb_id', name='uq_movies_tmdb_id'),
    )
    op.create_table(
        'people',
        sa.Column('id', sa.Integer, primary_key=True),
        sa.Column('tmdb_id', sa.Integer, nullable=False, unique=True),
        sa.Column('name', sa.String(255), nullable=False),
        sa.Column('profile_path', sa.String(255)),
    )
    op.create_table(
        'credits',
        sa.Column('id', sa.Integer, primary_key=True),
        sa.Column('movie_id', sa.Integer, nullable=False),
        sa.Column('person_id', sa.Integer, nullable=False),
        sa.Column('role', sa.String(64), nullable=False),  # cast/crew
        sa.Column('job', sa.String(128)),
        sa.Column('character', sa.String(128)),
        sa.ForeignKeyConstraint(['movie_id'], ['movies.id']),
        sa.ForeignKeyConstraint(['person_id'], ['people.id']),
    )
    op.create_table(
        'sources',
        sa.Column('id', sa.Integer, primary_key=True),
        sa.Column('name', sa.String(64), nullable=False),
        sa.Column('url', sa.String(512), nullable=False),
        sa.UniqueConstraint('url', name='uq_sources_url'),
    )
    op.create_table(
        'news',
        sa.Column('id', sa.Integer, primary_key=True),
        sa.Column('movie_id', sa.Integer),
        sa.Column('title', sa.String(255), nullable=False),
        sa.Column('summary', sa.Text),
        sa.Column('source_id', sa.Integer),
        sa.Column('published_at', sa.DateTime),
        sa.ForeignKeyConstraint(['movie_id'], ['movies.id']),
        sa.ForeignKeyConstraint(['source_id'], ['sources.id']),
    )
    op.create_table(
        'user_reviews',
        sa.Column('id', sa.Integer, primary_key=True),
        sa.Column('movie_id', sa.Integer, nullable=False),
        sa.Column('rating', sa.Integer),
        sa.Column('review_text', sa.Text),
        sa.Column('author', sa.String(128)),
        sa.Column('created_at', sa.DateTime, server_default=sa.text('now()')),
        sa.ForeignKeyConstraint(['movie_id'], ['movies.id']),
    )

def downgrade():
    for t in ('user_reviews','news','sources','credits','people','movies'):
        op.drop_table(t)
