import os
from typing import List
from fastapi import APIRouter
from PIL import Image, ImageDraw

router = APIRouter()

@router.get("/health")
def health():
    return {"ok": True}

@router.post("/static_touch")
def static_touch():
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # /app/app
    posters = os.path.join(base, "static", "posters")
    os.makedirs(posters, exist_ok=True)
    p = os.path.join(posters, "test.txt")
    with open(p, "w") as f:
        f.write("ok")
    return {"wrote": "/static/posters/test.txt"}

def _posters_dir() -> str:
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # /app/app
    posters = os.path.join(base, "static", "posters")
    os.makedirs(posters, exist_ok=True)
    return posters

def _make_poster(title: str, tagline: str = "") -> str:
    posters = _posters_dir()
    safe = title.replace(" ", "_")
    out = os.path.join(posters, f"{safe}.png")
    img = Image.new("RGB", (900, 1350), (24, 24, 24))
    d = ImageDraw.Draw(img)
    d.text((40, 40), title, fill=(235,235,235))
    if tagline:
        d.text((40, 120), tagline, fill=(180,180,180))
    img.save(out)
    return out

@router.get("/auto_generate")
def auto_generate() -> dict:
    titles: List[str] = [
        "Digital Mirage",
        "Neon Shakti",
        "AI Rising",
        "The Phoenix Code",
        "Quantum Edge",
    ]
    generated = []
    for t in titles:
        path = _make_poster(t, "Ek short teaser coming soon!")
        generated.append({
            "title": t,
            "poster": f"/static/posters/{os.path.basename(path)}",
        })
    return {"count": len(generated), "generated": generated}
