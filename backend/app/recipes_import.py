"""
Recipe import. Four ways in, one shape out.

  url    → Instagram and TikTok: the post caption and cover image, from their
           public oEmbed endpoints (Instagram's page HTML carries neither when
           fetched from a server). Any other site: schema.org/Recipe JSON-LD
           when the page has it, else og:title / og:description / visible text.
  image  → one to four photos (a cookbook page, a card, a screenshot), read
           directly by Gemini. Text recognised on the phone comes along and is
           used only if Gemini is unavailable.
  text   → typed or pasted; structured directly
  ocr    → text recognised on the phone (older app builds); same path as text

Structuring uses Gemini when GEMINI_API_KEY is set: the source goes in, and a
response schema constrains what comes out to exactly the fields the planner
uses, with every ingredient mapped to a catalog id when one fits. Without a key
a rule-based parser handles ingredient lines with quantities. Anything not in
the catalog becomes a custom ingredient with an estimated pack size and price.

The language model only ever reads. The planner decides.
"""
from __future__ import annotations

import base64
import copy
import json
import logging
import os
import re
import time
import uuid
from html import unescape
from html.parser import HTMLParser
from typing import Dict, List, Optional, Tuple
from urllib.parse import unquote, urlparse

import httpx

from .solver import CATALOG

log = logging.getLogger("heisoj.import")

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-flash-latest")
# Tried in order when the main model is overloaded (503/429) or retired (404).
GEMINI_FALLBACK_MODELS = [m.strip() for m in os.getenv("GEMINI_FALLBACK_MODELS", "gemini-2.5-flash,gemini-flash-lite-latest").split(",") if m.strip()]
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
MOBILE_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
MAX_IMAGES = 4
MAX_IMAGE_BYTES = 8_000_000
# Link → what Gemini read, for half an hour. The share sheet reads a reel, then the app asks for the
# same link a moment later and gets it instantly. Each hit is finalized again, so every import gets its own id.
URL_CACHE_SECONDS = 1800
_url_cache: Dict[str, Tuple[float, dict, str]] = {}


class ImportFailed(Exception):
    """A problem the user can act on. The message is shown in the app as-is."""


UNITS = ["g", "ml", "ea", "tsp", "tbsp", "cup", "slice", "bunch", "can", "pinch"]
SECTIONS = ["Produce", "Meat", "Seafood", "Dairy & Eggs", "Bakery", "Frozen", "Pantry", "Other"]
TAGS = ["meat", "poultry", "beef", "fish", "dairy", "eggs", "gluten", "soy", "nuts"]
EQUIPMENT = ["stove", "oven", "pan", "pot", "sheet_pan", "microwave", "blender"]
MOODS = ["quick", "comfort", "spicy", "light", "high_protein", "high_fiber", "one_pot", "batch", "breakfast"]

RECIPE_SCHEMA = {
    "type": "object",
    "properties": {
        "is_recipe": {"type": "boolean"},
        "completeness": {"type": "string", "enum": ["complete", "partial", "dish_only"]},
        "name": {"type": "string"},
        "servings": {"type": "integer"},
        "active_minutes": {"type": "integer"},
        "total_minutes": {"type": "integer"},
        "ingredients": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "catalog_id": {"type": "string", "enum": sorted(CATALOG.ingredients) + ["none"]},
                    "qty": {"type": "number"},
                    "unit": {"type": "string", "enum": UNITS},
                    "estimated_pack_qty": {"type": "number"},
                    "estimated_pack_price_usd": {"type": "number"},
                    "shelf_life_days": {"type": "integer"},
                    "perishable": {"type": "boolean"},
                    "section": {"type": "string", "enum": SECTIONS},
                    "tags": {"type": "array", "items": {"type": "string", "enum": TAGS}},
                },
                "required": ["name", "catalog_id", "qty", "unit"],
            },
        },
        "steps": {"type": "array", "items": {"type": "string"}},
        "equipment": {"type": "array", "items": {"type": "string", "enum": EQUIPMENT}},
        "tags": {"type": "array", "items": {"type": "string", "enum": TAGS}},
        "moods": {"type": "array", "items": {"type": "string", "enum": MOODS}},
        "keeps_days": {"type": "integer"},
    },
    "required": ["is_recipe", "completeness", "name", "servings", "active_minutes", "total_minutes", "ingredients", "steps", "equipment", "keeps_days"],
}

UNIT_TO_BASE = {"tsp": ("ml", 5), "tbsp": ("ml", 15), "cup": ("ml", 240), "pinch": ("g", 0.5), "can": ("ea", 1)}


# ------------------------------------------------------------- fetching ----

class _PageParser(HTMLParser):
    """Meta tags (any attribute order, any quoting), JSON-LD blocks, title, visible text."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.meta: Dict[str, str] = {}
        self.jsonld: List[str] = []
        self.title = ""
        self.text: List[str] = []
        self._ld: Optional[List[str]] = None
        self._in_title = False
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        a = {k.lower(): (v or "") for k, v in attrs}
        if tag == "meta":
            key = (a.get("property") or a.get("name") or "").lower()
            if key and "content" in a:
                self.meta.setdefault(key, a["content"])
        elif tag == "script":
            self._skip += 1
            if "ld+json" in a.get("type", "").lower():
                self._ld = []
        elif tag in ("style", "noscript", "svg", "template"):
            self._skip += 1
        elif tag == "title":
            self._in_title = True

    def handle_endtag(self, tag):
        if tag == "script":
            if self._ld is not None:
                self.jsonld.append("".join(self._ld))
                self._ld = None
            self._skip = max(0, self._skip - 1)
        elif tag in ("style", "noscript", "svg", "template"):
            self._skip = max(0, self._skip - 1)
        elif tag == "title":
            self._in_title = False

    def handle_data(self, data):
        if self._ld is not None:
            self._ld.append(data)
        elif self._in_title:
            self.title += data
        elif not self._skip and data.strip():
            self.text.append(data.strip())


async def read_link(raw: str) -> dict:
    """Title, text, and an optional cover image for any supported link."""
    m = re.search(r"https?://\S+", raw.strip())
    if not m:
        raise ImportFailed("That doesn't look like a link. It should start with https://")
    url = m.group(0).rstrip(").,;'\"")
    host = (urlparse(url).hostname or "").lower()
    async with httpx.AsyncClient(timeout=15, follow_redirects=True, headers={"User-Agent": UA, "Accept-Language": "en-US,en;q=0.9"}) as c:
        if host in ("instagram.com", "instagr.am") or host.endswith(".instagram.com"):
            page = await _instagram(c, url)
        elif host == "tiktok.com" or host.endswith(".tiktok.com"):
            page = await _tiktok(c, url)
        else:
            page = await _web_page(c, url)
        page["image"] = await _download_image(c, page["image_url"]) if page.get("image_url") else None
    return page


_IG_CODE = re.compile(r"/(?:p|reels?|tv)/([A-Za-z0-9_-]{5,})")


async def _instagram(c: httpx.AsyncClient, url: str) -> dict:
    m = _IG_CODE.search(urlparse(url).path)
    if not m:
        # instagram.com/share/... links redirect to the post (sometimes via the login page's ?next=)
        try:
            r = await c.get(url)
            m = _IG_CODE.search(unquote(str(r.url)))
        except httpx.HTTPError:
            m = None
    if not m:
        raise ImportFailed("That Instagram link isn't a post or reel. Open the post, tap Share, then Copy link.")
    code = m.group(1)
    canonical = f"https://www.instagram.com/p/{code}/"
    caption = image = author = ""
    try:
        r = await c.get("https://www.instagram.com/api/v1/oembed/", params={"url": canonical})
        if r.status_code == 200:
            d = r.json()
            caption, image, author = d.get("title") or "", d.get("thumbnail_url") or "", d.get("author_name") or ""
    except (httpx.HTTPError, ValueError):
        pass
    if not caption:
        try:
            r = await c.get(f"https://www.instagram.com/p/{code}/embed/captioned/", headers={"User-Agent": MOBILE_UA})
            if r.status_code == 200:
                embed_caption, embed_image = _instagram_embed(r.text)
                caption, image = embed_caption, image or embed_image
        except httpx.HTTPError:
            pass
    if not caption and not image:
        raise ImportFailed("Instagram didn't share that post. It may be private or removed. Paste the caption into Type instead.")
    return {"kind": "instagram", "title": f"Instagram post by @{author}" if author else "Instagram post",
            "text": caption, "image_url": image, "canonical": canonical}


def _instagram_embed(html: str) -> Tuple[str, str]:
    caption = ""
    m = re.search(r'<div class="Caption"[^>]*>(.*?)<div class="CaptionComments"', html, re.S) or re.search(r'<div class="Caption"[^>]*>(.*?)</div>', html, re.S)
    if m:
        body = re.sub(r'<a[^>]*class="CaptionUsername"[^>]*>.*?</a>', " ", m.group(1), flags=re.S)
        body = re.sub(r"<br\s*/?>", "\n", body)
        caption = unescape(re.sub(r"<[^>]+>", "", body)).strip()
    img = re.search(r'class="EmbeddedMediaImage"[^>]*src="([^"]+)"', html)
    return caption, unescape(img.group(1)) if img else ""


async def _tiktok(c: httpx.AsyncClient, url: str) -> dict:
    host = (urlparse(url).hostname or "").lower()
    if host.startswith(("vm.", "vt.")) or urlparse(url).path.startswith("/t/"):
        try:
            url = str((await c.get(url)).url)
        except httpx.HTTPError:
            pass
    url = url.split("?")[0]
    try:
        r = await c.get("https://www.tiktok.com/oembed", params={"url": url})
        d = r.json() if r.status_code == 200 else {}
    except (httpx.HTTPError, ValueError):
        d = {}
    if not d.get("title") and not d.get("thumbnail_url"):
        raise ImportFailed("TikTok didn't share that video. It may be private. Paste the caption into Type instead.")
    author = d.get("author_name") or ""
    return {"kind": "tiktok", "title": f"TikTok by {author}" if author else "TikTok video",
            "text": d.get("title") or "", "image_url": d.get("thumbnail_url") or "", "canonical": url}


async def _web_page(c: httpx.AsyncClient, url: str) -> dict:
    try:
        r = await c.get(url)
    except httpx.HTTPError:
        raise ImportFailed("Couldn't open that link. Check it and try again.")
    if r.status_code in (401, 403, 429):
        raise ImportFailed("That site blocks automatic reading. Copy the ingredients and steps into Type instead.")
    if r.status_code >= 400:
        raise ImportFailed(f"That link returned an error ({r.status_code}).")
    if "html" not in r.headers.get("content-type", "html"):
        raise ImportFailed("That link isn't a web page.")
    p = _PageParser()
    p.feed(r.text)
    p.close()
    for block in p.jsonld:
        try:
            data = json.loads(block.strip())
        except json.JSONDecodeError:
            continue
        rec = _find_recipe_node(data)
        if rec:
            return {"kind": "jsonld", "title": _as_text(rec.get("name")), "text": jsonld_to_text(rec), "image_url": "", "canonical": str(r.url)}
    title = p.meta.get("og:title") or p.title.strip()
    desc = p.meta.get("og:description") or p.meta.get("description") or ""
    visible = "\n".join(p.text)[:10000]
    return {"kind": "web", "title": title, "text": "\n\n".join(x for x in (title, desc, visible) if x),
            "image_url": p.meta.get("og:image", ""), "canonical": str(r.url)}


async def _download_image(c: httpx.AsyncClient, url: str) -> Optional[Tuple[str, bytes]]:
    try:
        r = await c.get(url)
    except httpx.HTTPError:
        return None
    mime = r.headers.get("content-type", "").split(";")[0].strip()
    if r.status_code != 200 or not mime.startswith("image/") or len(r.content) > MAX_IMAGE_BYTES:
        return None
    return mime, r.content


def _find_recipe_node(data):
    if isinstance(data, dict):
        t = data.get("@type")
        if t == "Recipe" or (isinstance(t, list) and "Recipe" in t):
            return data
        for v in data.values():
            found = _find_recipe_node(v)
            if found:
                return found
    elif isinstance(data, list):
        for v in data:
            found = _find_recipe_node(v)
            if found:
                return found
    return None


def _as_text(v) -> str:
    if isinstance(v, list):
        return ", ".join(_as_text(x) for x in v)
    return re.sub(r"<[^>]+>", " ", unescape(str(v or ""))).strip()


def _instructions(x) -> List[str]:
    if isinstance(x, str):
        return [s.strip() for s in _as_text(x).splitlines() if s.strip()]
    if isinstance(x, list):
        return [s for item in x for s in _instructions(item)]
    if isinstance(x, dict):
        if x.get("itemListElement"):
            return _instructions(x["itemListElement"])
        return _instructions(x.get("text") or x.get("name") or "")
    return []


def jsonld_to_text(rec: dict) -> str:
    parts = [f"Recipe: {_as_text(rec.get('name'))}"]
    if rec.get("recipeYield"):
        parts.append(f"Yield: {_as_text(rec['recipeYield'])}")
    for k in ("prepTime", "cookTime", "totalTime"):
        if rec.get(k):
            parts.append(f"{k}: {rec[k]}")
    parts.append("Ingredients:")
    parts += [f"- {_as_text(x)}" for x in rec.get("recipeIngredient", []) or []]
    parts.append("Steps:")
    parts += [f"- {s}" for s in _instructions(rec.get("recipeInstructions", []))]
    return "\n".join(parts)


_MAGIC = ((b"\xff\xd8\xff", "image/jpeg"), (b"\x89PNG\r\n\x1a\n", "image/png"))


def decode_images(items: List[str]) -> List[Tuple[str, bytes]]:
    """Base64 photos from the app → (mime, bytes). JPEG, PNG, WebP, HEIC."""
    out = []
    for s in items[:MAX_IMAGES]:
        s = s.split(",", 1)[-1] if s.startswith("data:") else s
        try:
            b = base64.b64decode(s)
        except ValueError:
            raise ImportFailed("One of the photos couldn't be read. Try taking it again.")
        mime = next((m for sig, m in _MAGIC if b.startswith(sig)), None)
        if not mime and b[:4] == b"RIFF" and b[8:12] == b"WEBP":
            mime = "image/webp"
        if not mime and b[4:8] == b"ftyp" and b[8:12] in (b"heic", b"heix", b"mif1", b"msf1", b"hevc"):
            mime = "image/heic"
        if not mime:
            raise ImportFailed("Photos need to be JPEG, PNG, WebP, or HEIC.")
        if len(b) > MAX_IMAGE_BYTES:
            raise ImportFailed("One of the photos is too large. Try again with a smaller one.")
        out.append((mime, b))
    if not out:
        raise ImportFailed("Add a photo of the recipe first.")
    return out


# ---------------------------------------------------------- structuring ----

async def structure(text: str, hint: str = "", images: Optional[List[Tuple[str, bytes]]] = None, context: str = "") -> dict:
    images = images or []
    if GEMINI_API_KEY:
        try:
            out = await _gemini(text, hint, images, context)
            out["_by"] = "gemini"
            return out
        except Exception as e:  # noqa: BLE001
            log.warning("Gemini failed: %s", e)
            if not (text.strip() or hint.strip()):
                raise ImportFailed("Couldn't read that right now. Try again in a moment.") from e
            fallback = _rule_based(text, hint)
            fallback["_warning"] = "The recipe reader is unavailable, so a basic parser was used. Check quantities."
            return fallback
    if not (text.strip() or hint.strip()):
        raise ImportFailed("Reading photos needs GEMINI_API_KEY on the server.")
    out = _rule_based(text, hint)
    out["_warning"] = "No GEMINI_API_KEY set; used the basic parser. Check quantities."
    return out


def _prompt(text: str, hint: str, n_images: int, context: str) -> str:
    catalog = "\n".join(f"- {i.id} ({i.unit}): {i.name}" for i in CATALOG.ingredients.values())
    source = []
    if n_images:
        source.append(f"The recipe is in the {'photo' if n_images == 1 else f'{n_images} photos (pages of the same recipe, in order)'} above."
                      " Read printed and handwritten text, and use what the food looks like only to fill gaps.")
    if context:
        source.append(f"Where it came from: {context}")
    if hint:
        source.append(f"The user calls it: {hint}")
    if text.strip():
        source.append(("Text recognised from the photos (may contain errors; the photos win):\n" if n_images else "Source text:\n") + text[:12000])
    return (
        "Extract one cooking recipe for a meal planner. Output only the JSON the schema describes.\n\n"
        "Rules:\n"
        "- is_recipe: false only if the source has no dish or recipe in it at all.\n"
        "- completeness: complete if the source gives ingredients with quantities and the method; partial if you had to estimate some "
        "quantities, times, or steps; dish_only if the source only names or shows a dish and you wrote the recipe yourself.\n"
        "- If the source only names or shows a dish, or gives a rough ingredient list, write a sensible complete home recipe for it.\n"
        "- If the source has several recipes, take the main one.\n"
        "- List each thing to buy once: the oil in a jar of sun-dried tomatoes or the pasta water is not a separate ingredient.\n"
        "- Ignore everything that isn't the recipe: hashtags, sponsorships, calls to like, follow, or comment, and life stories.\n"
        "- catalog_id: the id from the catalog below when the ingredient is that same product, else \"none\". Rice vinegar is not rice, "
        "chicken stock is not chicken, garlic powder is not garlic. Salt, pepper, and oil count.\n"
        "- qty and unit: when catalog_id is set, unit must be that catalog item's unit; convert with realistic weights (1 tsp of a dried spice "
        "is about 2 g, a 400 g can of chickpeas drains to about 240 g, 1 clove of garlic is 1 ea). Otherwise prefer g, ml, or ea; use tsp, "
        "tbsp, or cup only when a weight is unclear. Turn \"to taste\" into a small realistic amount.\n"
        "- For ingredients with catalog_id \"none\", estimate a typical US grocery pack size (in the same unit), its price in USD, shelf life "
        "in days from purchase, whether it is perishable, its store section, and allergen tags.\n"
        "- servings: how many single-person meals it makes. active_minutes: hands-on time. total_minutes: including oven and waiting time. "
        "keeps_days: days the cooked dish keeps in the fridge.\n"
        "- equipment: what is actually needed; an empty list for no-cook dishes.\n"
        "- steps: short imperative sentences in order, in English (translate if needed), without numbering.\n\n"
        f"Catalog (id (unit): name):\n{catalog}\n\n"
        + "\n\n".join(source)
    )


async def _gemini(text: str, hint: str, images: List[Tuple[str, bytes]], context: str) -> dict:
    parts: List[dict] = [{"inline_data": {"mime_type": mime, "data": base64.b64encode(data).decode()}} for mime, data in images]
    parts.append({"text": _prompt(text, hint, len(images), context)})
    body = {
        "contents": [{"role": "user", "parts": parts}],
        "generationConfig": {"responseMimeType": "application/json", "responseSchema": RECIPE_SCHEMA, "temperature": 0.2},
    }
    models = [GEMINI_MODEL] + [m for m in GEMINI_FALLBACK_MODELS if m != GEMINI_MODEL]
    started, errors, data = time.monotonic(), [], None
    async with httpx.AsyncClient(timeout=httpx.Timeout(40, connect=10)) as c:
        for model in models:
            if time.monotonic() - started > 50:   # the app gives up at 90 s
                break
            url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
            try:
                r = await c.post(url, json=body, headers={"x-goog-api-key": GEMINI_API_KEY})
            except httpx.TimeoutException:
                errors.append(f"{model}: timeout")
                continue
            if r.status_code == 200:
                data = r.json()
                break
            errors.append(f"{model}: HTTP {r.status_code} {r.text[:160]}")
            if r.status_code not in (404, 429, 500, 503):
                break
    if data is None:
        raise RuntimeError("; ".join(errors) or "no model tried")
    candidates = data.get("candidates") or []
    if not candidates:
        raise RuntimeError(f"no candidates: {data.get('promptFeedback')}")
    raw = "".join(p.get("text", "") for p in candidates[0].get("content", {}).get("parts", []) if not p.get("thought"))
    if not raw:
        raise RuntimeError(f"empty response, finishReason={candidates[0].get('finishReason')}")
    return json.loads(raw)


_QTY = re.compile(r"^\s*(?:[-*•]\s*)?(\d+(?:[.,]\d+)?|\d+\s*/\s*\d+|½|¼|¾)?\s*(g|kg|ml|l|tsp|tbsp|cups?|cup|oz|lb|cans?|cloves?|slices?|bunch|pinch)?\s*(?:of\s+)?(.+?)\s*$", re.I)
_FRAC = {"½": 0.5, "¼": 0.25, "¾": 0.75}


def _rule_based(text: str, hint: str) -> dict:
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    name = hint or (lines[0][:60] if lines else "My recipe")
    ingredients, steps = [], []
    for l in lines:
        m = _QTY.match(l)
        if m and (m.group(1) or m.group(2)) and len(l) < 80:
            q_raw, unit, nm = m.group(1), (m.group(2) or "ea").lower(), m.group(3)
            if q_raw in _FRAC:
                q = _FRAC[q_raw]
            elif q_raw and "/" in q_raw:
                a, b = q_raw.split("/")
                q = float(a) / float(b)
            else:
                q = float(q_raw.replace(",", ".")) if q_raw else 1.0
            unit = {"cups": "cup", "cans": "can", "cloves": "ea", "clove": "ea", "slices": "slice", "kg": "g", "l": "ml", "oz": "g", "lb": "g"}.get(unit, unit)
            if unit == "g" and m.group(2) and m.group(2).lower() in ("oz",):
                q *= 28
            if unit == "g" and m.group(2) and m.group(2).lower() in ("lb",):
                q *= 454
            if m.group(2) and m.group(2).lower() == "kg":
                q *= 1000
            if m.group(2) and m.group(2).lower() == "l":
                q *= 1000
            ingredients.append({"name": nm.strip(" ,."), "qty": round(q, 2), "unit": unit})
        elif len(l) > 25 and re.match(r"^(\d+[.)]\s*|step\s*\d+|[-*•]\s*)?[A-Z]", l):
            steps.append(re.sub(r"^(\d+[.)]\s*|step\s*\d+[:.]?\s*|[-*•]\s*)", "", l, flags=re.I))
    if not ingredients:
        ingredients = [{"name": name, "qty": 1, "unit": "ea"}]
    return {"name": name, "servings": 2, "active_minutes": 25, "total_minutes": 35, "ingredients": ingredients,
            "steps": steps or ["Cook according to the source."], "equipment": ["stove", "pan"], "tags": [], "moods": [], "keeps_days": 3,
            "_by": "rules"}


# ------------------------------------------------------------ matching ----

_SYN = {
    "chicken": "chicken_thighs", "chicken breast": "chicken_thighs", "chicken thigh": "chicken_thighs", "whole chicken": "chicken_whole",
    "beef": "ground_beef", "mince": "ground_beef", "egg": "eggs", "tomato": "tomato", "tomatoes": "tomato", "canned tomato": "crushed_tomatoes",
    "crushed tomato": "crushed_tomatoes", "tomato sauce": "crushed_tomatoes", "passata": "crushed_tomatoes", "onion": "onion", "garlic": "garlic",
    "rice": "rice", "pasta": "pasta", "spaghetti": "pasta", "penne": "pasta", "noodle": "pasta", "flour tortilla": "tortillas", "tortilla": "tortillas",
    "cheese": "cheddar", "cheddar": "cheddar", "milk": "milk", "yogurt": "yogurt", "yoghurt": "yogurt", "butter": "butter", "bread": "bread",
    "oat": "oats", "flour": "flour", "black bean": "black_beans_dry", "beans": "black_beans_dry", "lentil": "lentils", "chickpea": "chickpeas_can",
    "coconut milk": "coconut_milk", "peanut butter": "peanut_butter", "soy sauce": "soy_sauce", "olive oil": "olive_oil", "oil": "olive_oil",
    "salt": "salt", "pepper": "pepper", "black pepper": "pepper", "cumin": "cumin", "paprika": "paprika", "curry": "curry_powder", "chili flake": "chili_flakes",
    "red pepper flake": "chili_flakes", "potato": "potato", "carrot": "carrot", "bell pepper": "bell_pepper", "pepper (bell)": "bell_pepper", "capsicum": "bell_pepper",
    "broccoli": "broccoli", "spinach": "spinach", "cilantro": "cilantro", "coriander": "cilantro", "lime": "lime", "lemon": "lemon", "banana": "banana",
    "ginger": "ginger", "pea": "frozen_peas", "frozen veg": "frozen_mixed_veg", "mixed vegetable": "frozen_mixed_veg", "tofu": "tofu",
    "salmon": "salmon", "tuna": "canned_tuna",
}

# Words that turn a catalog item into a different product: "chicken stock" is not chicken.
_OTHER_PRODUCT = {"stock", "broth", "vinegar", "paste", "powder", "extract", "bouillon", "cube", "cubes", "sauce", "cream", "sweet"}


def _norm(s: str) -> str:
    s = s.lower()
    s = re.sub(r"\(.*?\)", " ", s)
    s = re.sub(r"[^a-z ]", " ", s)
    s = re.sub(r"\b(fresh|large|small|medium|chopped|diced|minced|sliced|ripe|boneless|skinless|of|the|a|an|to taste|optional)\b", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def _different_product(n: str, key: str) -> bool:
    return bool((set(n.split()) - set(key.split())) & _OTHER_PRODUCT)


def match_ingredient(name: str) -> Optional[str]:
    n = _norm(name)
    if not n:
        return None
    if n in CATALOG.ingredients:
        return n
    for k in sorted(_SYN, key=len, reverse=True):
        if re.search(rf"\b{re.escape(k)}(?:e?s)?\b", n) and not _different_product(n, k):
            return _SYN[k]
    for ing in CATALOG.ingredients.values():
        base = _norm(ing.name)
        if (base == n or re.search(rf"\b{re.escape(base.rstrip('s'))}(?:e?s)?\b", n)) and not _different_product(n, base):
            return ing.id
    return None


def to_catalog_units(qty: float, unit: str, target_unit: str) -> Tuple[float, str]:
    unit = unit.lower()
    if unit in UNIT_TO_BASE:
        base, factor = UNIT_TO_BASE[unit]
        qty, unit = qty * factor, base
    if unit == target_unit:
        return qty, unit
    if unit == "ml" and target_unit == "g":
        return qty, "g"
    if unit == "g" and target_unit == "ml":
        return qty, "ml"
    if unit in ("g", "ml") and target_unit == "ea":
        return max(1.0, round(qty / 120)), "ea"
    if unit == "ea" and target_unit in ("g", "ml"):
        return qty * 120, target_unit
    return qty, target_unit


def _num(v, default: float) -> float:
    try:
        f = float(v)
        return f if f > 0 else default
    except (TypeError, ValueError):
        return default


def _int_in(v, default: int, lo: int, hi: int) -> int:
    return int(min(hi, max(lo, round(_num(v, default)))))


_COMPLETENESS_WARNING = {
    "partial": "Some quantities or times weren't in the source and were estimated. Check them before saving.",
    "dish_only": "The source didn't include the full recipe, so this one was written from the dish. Check it before saving.",
}


def finalize(structured: dict, source: str, source_ref: str = "") -> dict:
    """Attach catalog ids; invent custom ingredients for anything unmatched."""
    rid = "mine_" + uuid.uuid4().hex[:10]
    by_gemini = structured.get("_by") == "gemini"
    custom: Dict[str, dict] = {}
    rows: Dict[str, dict] = {}
    tags = {t for t in structured.get("tags") or [] if t in TAGS}
    for x in structured.get("ingredients") or []:
        name = str(x.get("name", "")).strip()
        if not name:
            continue
        qty = _num(x.get("qty"), 1.0)
        unit = str(x.get("unit") or "ea").lower()
        # Gemini chose from the catalog with the whole list in view; trust its "none".
        cid = x.get("catalog_id") if by_gemini else match_ingredient(name)
        if cid in CATALOG.ingredients:
            ing = CATALOG.ingredients[cid]
            q, u = to_catalog_units(qty, unit, ing.unit)
            row_id, row_name, matched = cid, ing.name, True
            tags |= set(ing.tags)
        else:
            base_unit = UNIT_TO_BASE[unit][0] if unit in UNIT_TO_BASE else (unit if unit in ("g", "ml", "ea", "slice", "bunch") else "ea")
            q, u = to_catalog_units(qty, unit, base_unit)
            slug = re.sub(r"[^a-z0-9]+", "_", _norm(name))[:30].strip("_")
            row_id = "custom_" + (slug or uuid.uuid4().hex[:6])
            if row_id in custom and custom[row_id]["unit"] != u:
                row_id += "_" + u
            row_name, matched = name[:1].upper() + name[1:], False
            if row_id not in custom:
                pack_qty, _ = to_catalog_units(_num(x.get("estimated_pack_qty"), 0) or max(qty, 1.0), unit, u)
                ing_tags = [t for t in x.get("tags") or [] if t in TAGS]
                custom[row_id] = {
                    "id": row_id, "name": row_name, "unit": u,
                    "pack_qty": round(max(pack_qty, q, 1.0), 1),
                    "pack_price": round(_num(x.get("estimated_pack_price_usd"), 3.49), 2),
                    "shelf_life_days": _int_in(x.get("shelf_life_days"), 7, 1, 3650),
                    "perishable": bool(x.get("perishable", True)),
                    "section": x.get("section") if x.get("section") in SECTIONS else "Other",
                    "tags": ing_tags, "staple": False,
                }
                tags |= set(ing_tags)
        if row_id in rows:
            rows[row_id]["qty"] = round(rows[row_id]["qty"] + q, 1)
        else:
            rows[row_id] = {"id": row_id, "name": row_name, "qty": max(round(q, 1), 0.1), "unit": u, "matched": matched}
    if not rows:
        raise ImportFailed("Couldn't find any ingredients in that. Try a clearer photo, or type the recipe.")

    active = _int_in(structured.get("active_minutes"), 25, 1, 600)
    equipment = [e for e in structured.get("equipment") or [] if e in EQUIPMENT]
    steps = [re.sub(r"^\s*(\d+[.)]|step\s*\d+[:.]?)\s*", "", str(s), flags=re.I).strip() for s in structured.get("steps") or []]
    recipe = {
        "id": rid, "name": (str(structured.get("name") or "").strip() or "My recipe")[:80],
        "meals": _int_in(structured.get("servings"), 2, 1, 12),
        "active_minutes": active,
        "total_minutes": max(active, _int_in(structured.get("total_minutes"), 35, 1, 1440)),
        "keeps_days": _int_in(structured.get("keeps_days"), 3, 1, 7),
        "ingredients": list(rows.values()), "consumes": [], "produces": [],
        "equipment": equipment if by_gemini else (equipment or ["stove", "pan"]),
        "techniques": [], "tags": sorted(tags), "steps": [s for s in steps if s] or ["Cook according to the source."],
        "moods": [m for m in structured.get("moods") or [] if m in MOODS], "source": source, "source_ref": source_ref,
    }
    warning = structured.get("_warning") or _COMPLETENESS_WARNING.get(structured.get("completeness", ""))
    return {"recipe": recipe, "custom_ingredients": list(custom.values()), "warning": warning}


_NOT_A_RECIPE = {
    "image": "That photo doesn't look like a recipe. Try a closer, straighter shot of the ingredients and steps.",
    "url": "Couldn't find a recipe in that link. If it's only in the video, type the dish name in Type instead.",
}


async def import_recipe(source: str, url: str = "", text: str = "", hint: str = "", images: Optional[List[str]] = None) -> dict:
    source_ref = ""
    if source == "url":
        key = url.strip()
        hit = _url_cache.get(key)
        if hit and time.monotonic() - hit[0] < URL_CACHE_SECONDS:
            return finalize(copy.deepcopy(hit[1]), source, hit[2])
        page = await read_link(url)
        # A recipe site's JSON-LD is authoritative; a post's cover image often has the ingredients written on it.
        pics = [page["image"]] if page.get("image") and page["kind"] != "jsonld" else []
        context = {"instagram": f"{page['title']} (the caption and the cover image)", "tiktok": f"{page['title']} (the caption and the cover image)",
                   "jsonld": "a recipe website's structured data", "web": "a web page"}[page["kind"]]
        structured = await structure(page["text"], hint, pics, context)
        source_ref = page["canonical"]
        if structured.get("_by") == "gemini" and structured.get("is_recipe") is not False and not hint:
            while len(_url_cache) >= 500:
                _url_cache.pop(next(iter(_url_cache)))
            _url_cache[key] = (time.monotonic(), copy.deepcopy(structured), source_ref)
    elif source == "image":
        structured = await structure(text, hint, decode_images(images or []), "photos taken in the app")
    else:
        structured = await structure(text, hint)
    if structured.get("is_recipe") is False:
        raise ImportFailed(_NOT_A_RECIPE.get(source, "That doesn't look like a recipe."))
    return finalize(structured, source, source_ref)
