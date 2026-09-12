import logging
import os
import time

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response
from pymongo.errors import PyMongoError
from starlette.concurrency import run_in_threadpool

from . import db
from .auth import auth0_enabled, current_user, hash_password, issue_token, verify_password
from .models import (FitRecipeModel, ForgotModel, ImportRecipeModel, LoginModel, PlanRequestModel, ProfileModel, RegisterModel,
                     SavePlanModel, SaveRecipeModel, TTSModel)
from .recipes_import import GEMINI_API_KEY, GEMINI_MODEL, ImportFailed, import_recipe
from .solver import CATALOG, PlanRequest, plan

log = logging.getLogger("heisoj")

app = FastAPI(title="heisoj", version="2.0.0", description="Cook a few times. Eat all week.")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


@app.exception_handler(RequestValidationError)
async def validation_error(_: Request, exc: RequestValidationError):
    first = exc.errors()[0]
    field = ".".join(str(x) for x in first.get("loc", []) if x != "body")
    msg = first.get("msg", "Invalid input").replace("Value error, ", "")
    return JSONResponse(status_code=422, content={"detail": f"{field}: {msg}" if field else msg})


@app.exception_handler(PyMongoError)
async def mongo_down(_: Request, exc: PyMongoError):
    return JSONResponse(status_code=503, content={"detail": "Database unreachable. Try again in a moment."})


# ---- meta ------------------------------------------------------------------

@app.get("/")
async def root():
    return {"app": "heisoj", "tagline": "Cook a few times. Eat all week.", "docs": "/docs"}


@app.get("/health")
async def health():
    return {"ok": True, "auth0": auth0_enabled(), "db": db.backend_name(), "recipes": len(CATALOG.recipes),
            "gemini": GEMINI_MODEL if GEMINI_API_KEY else False, "elevenlabs": bool(os.getenv("ELEVENLABS_API_KEY"))}


@app.get("/catalog")
async def catalog():
    return {
        "recipes": CATALOG.recipe_dicts(),
        "ingredients": [i.__dict__ for i in CATALOG.ingredients.values()],
        "components": [c.__dict__ for c in CATALOG.components.values()],
        "tags": sorted({t for r in CATALOG.recipes.values() for t in r.tags} | {t for i in CATALOG.ingredients.values() for t in i.tags}),
        "equipment": sorted({e for r in CATALOG.recipes.values() for e in r.equipment}),
        "moods": sorted({m for r in CATALOG.recipes.values() for m in r.moods}),
    }


# ---- auth ------------------------------------------------------------------

def _public_user(u: dict) -> dict:
    return {"id": u["_id"], "email": u["email"], "name": u.get("name", ""), "created_at": u.get("created_at")}


@app.post("/auth/register")
async def register(body: RegisterModel):
    if await db.get_user_by_email(body.email):
        raise HTTPException(409, "An account with that email already exists")
    u = await db.create_user(body.email, hash_password(body.password), body.name)
    if body.device_id:
        await db.migrate_guest("device|" + body.device_id, u["_id"])
    return {"token": issue_token(u["_id"], u["email"]), "user": _public_user(u)}


@app.post("/auth/login")
async def login(body: LoginModel):
    u = await db.get_user_by_email(body.email)
    if not u or not verify_password(body.password, u["password_hash"]):
        raise HTTPException(401, "Email or password is incorrect")
    if body.device_id:
        await db.migrate_guest("device|" + body.device_id, u["_id"])
    return {"token": issue_token(u["_id"], u["email"]), "user": _public_user(u)}


@app.post("/auth/forgot")
async def forgot(body: ForgotModel):
    return {"ok": True}


@app.get("/auth/me")
async def me(user: str = Depends(current_user)):
    if user.startswith("user|"):
        u = await db.get_user(user)
        if u:
            return {"kind": "account", **_public_user(u)}
    if user.startswith("auth0|"):
        return {"kind": "auth0", "id": user}
    return {"kind": "guest", "id": user}


# ---- profile ---------------------------------------------------------------

@app.get("/profile")
async def get_profile(user: str = Depends(current_user)):
    p = await db.get_profile(user)
    if p is None:
        raise HTTPException(404, "No profile yet")
    return p


@app.put("/profile")
async def put_profile(body: ProfileModel, user: str = Depends(current_user)):
    await db.put_profile(user, body.model_dump())
    return {"ok": True}


# ---- recipes ---------------------------------------------------------------

@app.post("/recipes/import")
async def recipes_import(body: ImportRecipeModel):
    """Turn a link, photos, typed text, or scanned text into a structured recipe. Nothing is saved yet."""
    try:
        return await import_recipe(body.source, url=body.url, text=body.text, hint=body.hint, images=body.images)
    except ImportFailed as e:
        raise HTTPException(422, str(e))
    except Exception:  # noqa: BLE001
        log.exception("recipe import failed (source=%s)", body.source)
        raise HTTPException(422, "Couldn't read that recipe. Try again, or type it in.")


def _week(p: dict) -> dict:
    return {k: p[k] for k in ("total_cost", "meals_planned", "meals_required", "distinct_ingredients", "waste_plan")}


@app.post("/recipes/fit")
async def recipes_fit(body: FitRecipeModel, user: str = Depends(current_user)):
    """What adding one imported recipe does to the week: the same planner, run without it and with it pinned."""
    rid = str(body.recipe.get("id", ""))
    if not rid.startswith("mine_"):
        raise HTTPException(422, "Recipe must come from /recipes/import")
    mine = [d for d in await db.list_recipes(user) if d["_id"] != rid]
    extra_recipes = [d["recipe"] for d in mine]
    extra_ingredients = [c for d in mine for c in d.get("custom_ingredients", [])]
    req = body.request.model_dump()
    req["pinned_recipe_ids"] = [x for x in req["pinned_recipe_ids"] if x != rid]
    before = await run_in_threadpool(plan, PlanRequest(**req, extra_recipes=extra_recipes, extra_ingredients=extra_ingredients))
    after = await run_in_threadpool(plan, PlanRequest(**{**req, "pinned_recipe_ids": req["pinned_recipe_ids"] + [rid]},
                                                      extra_recipes=extra_recipes + [body.recipe],
                                                      extra_ingredients=extra_ingredients + body.custom_ingredients))
    included = any(r["id"] == rid for r in after["recipes"])
    was = {i["id"]: i for i in before["shopping"]}
    now = {i["id"]: i for i in after["shopping"]}
    uses = {i.get("id") for i in body.recipe.get("ingredients", [])}
    added = [{"name": i["name"], "cost": round(i["cost"] - was.get(k, {}).get("cost", 0), 2)} for k, i in now.items()
             if i["cost"] - was.get(k, {}).get("cost", 0) > 0.005]
    after_ids = {r["id"] for r in after["recipes"]}
    return {
        "included": included,
        "reason": None if included else next((w for w in after["warnings"] if "pinned" in w), "It doesn't fit this week's limits."),
        "before": _week(before), "after": _week(after),
        "cost_delta": round(after["total_cost"] - before["total_cost"], 2),
        # bought for the week anyway, so this recipe shares the pack instead of starting a new one
        "reused": sorted(was[i]["name"] for i in uses if i in was and was[i]["cost"] > 0),
        "new_items": sorted(added, key=lambda x: -x["cost"])[:6],
        "replaced": [r["name"] for r in before["recipes"] if r["id"] not in after_ids],
    }


@app.post("/recipes")
async def recipes_save(body: SaveRecipeModel, user: str = Depends(current_user)):
    if "id" not in body.recipe or not str(body.recipe["id"]).startswith("mine_"):
        raise HTTPException(422, "Recipe must come from /recipes/import")
    doc = await db.save_recipe(user, body.recipe, body.custom_ingredients)
    return {"id": doc["_id"], "created_at": doc["created_at"]}


@app.get("/recipes")
async def recipes_mine(user: str = Depends(current_user)):
    return [{"id": d["_id"], "created_at": d["created_at"], "recipe": d["recipe"], "custom_ingredients": d.get("custom_ingredients", [])}
            for d in await db.list_recipes(user)]


@app.delete("/recipes/{recipe_id}")
async def recipes_delete(recipe_id: str, user: str = Depends(current_user)):
    if not await db.delete_recipe(user, recipe_id):
        raise HTTPException(404, "Not found")
    return {"ok": True}


# ---- planning --------------------------------------------------------------

@app.post("/plan")
async def make_plan(req: PlanRequestModel, user: str = Depends(current_user)):
    """The planner. The user's saved recipes are always in the candidate pool."""
    mine = await db.list_recipes(user)
    extra_recipes = [d["recipe"] for d in mine]
    extra_ingredients = [c for d in mine for c in d.get("custom_ingredients", [])]
    t0 = time.perf_counter()
    result = plan(PlanRequest(**req.model_dump(), extra_recipes=extra_recipes, extra_ingredients=extra_ingredients))
    result["solve_ms"] = round((time.perf_counter() - t0) * 1000, 1)
    return result


@app.post("/plans")
async def save(body: SavePlanModel, user: str = Depends(current_user)):
    doc = await db.save_plan(user, body.name, body.plan)
    return {"id": doc["_id"], "name": doc["name"], "created_at": doc["created_at"]}


@app.get("/plans")
async def mine(user: str = Depends(current_user)):
    docs = await db.list_plans(user)
    return [{"id": d["_id"], "name": d["name"], "created_at": d["created_at"],
             "total_cost": d.get("plan", {}).get("total_cost", 0),
             "meals_planned": d.get("plan", {}).get("meals_planned", 0),
             "meals_required": d.get("plan", {}).get("meals_required", 0)} for d in docs]


@app.get("/plans/{plan_id}")
async def one(plan_id: str, user: str = Depends(current_user)):
    d = await db.get_plan(user, plan_id)
    if not d:
        raise HTTPException(404, "Not found")
    return {"id": d["_id"], "name": d["name"], "created_at": d["created_at"], "plan": d["plan"]}


@app.delete("/plans/{plan_id}")
async def remove(plan_id: str, user: str = Depends(current_user)):
    if not await db.delete_plan(user, plan_id):
        raise HTTPException(404, "Not found")
    return {"ok": True}


# ---- voice (ElevenLabs, optional) -----------------------------------------

@app.post("/tts")
async def tts(body: TTSModel):
    key = os.getenv("ELEVENLABS_API_KEY")
    if not key:
        raise HTTPException(503, "Voice isn't configured on this server")
    import httpx
    voice = os.getenv("ELEVENLABS_VOICE_ID", "21m00Tcm4TlvDq8ikWAM")
    async with httpx.AsyncClient(timeout=30) as c:
        r = await c.post(f"https://api.elevenlabs.io/v1/text-to-speech/{voice}", headers={"xi-api-key": key},
                         json={"text": body.text, "model_id": "eleven_turbo_v2_5"})
    if r.status_code != 200:
        raise HTTPException(502, "Voice request failed")
    return Response(content=r.content, media_type="audio/mpeg")
