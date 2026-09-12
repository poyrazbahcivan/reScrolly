"""
Storage. MongoDB Atlas when MONGO_URI is set, else in-memory dicts so the
service runs with zero configuration. Same interface either way.

Collections: users, profiles, plans.
"""
import os
import uuid
from datetime import datetime, timezone
from typing import Dict, List, Optional

MONGO_URI = os.getenv("MONGO_URI")
MONGO_DB = os.getenv("MONGO_DB", "rescrolly")

_users: Dict[str, dict] = {}
_profiles: Dict[str, dict] = {}
_plans: Dict[str, dict] = {}
_recipes: Dict[str, dict] = {}
_db = None

if MONGO_URI:
    from motor.motor_asyncio import AsyncIOMotorClient
    _db = AsyncIOMotorClient(MONGO_URI)[MONGO_DB]


def backend_name() -> str:
    return "mongodb" if _db is not None else "memory"


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


# ---- users -----------------------------------------------------------------

async def get_user_by_email(email: str) -> Optional[dict]:
    email = email.lower().strip()
    if _db is not None:
        return await _db.users.find_one({"email": email})
    return next((u for u in _users.values() if u["email"] == email), None)


async def get_user(user_id: str) -> Optional[dict]:
    if _db is not None:
        return await _db.users.find_one({"_id": user_id})
    return _users.get(user_id)


async def create_user(email: str, password_hash: str, name: str) -> dict:
    doc = {"_id": "user|" + uuid.uuid4().hex, "email": email.lower().strip(), "name": name.strip(), "password_hash": password_hash, "created_at": _now()}
    if _db is not None:
        await _db.users.insert_one(doc)
    else:
        _users[doc["_id"]] = doc
    return doc


# ---- profiles --------------------------------------------------------------

async def get_profile(user_id: str) -> Optional[dict]:
    if _db is not None:
        d = await _db.profiles.find_one({"_id": user_id})
        return d["profile"] if d else None
    return _profiles.get(user_id)


async def put_profile(user_id: str, profile: dict) -> None:
    if _db is not None:
        await _db.profiles.replace_one({"_id": user_id}, {"_id": user_id, "profile": profile, "updated_at": _now()}, upsert=True)
    else:
        _profiles[user_id] = profile


async def migrate_guest(device_user: str, account_user: str) -> None:
    """When a guest creates an account, move their profile and plans across."""
    if _db is not None:
        p = await _db.profiles.find_one({"_id": device_user})
        if p and not await _db.profiles.find_one({"_id": account_user}):
            await _db.profiles.insert_one({"_id": account_user, "profile": p["profile"], "updated_at": _now()})
        await _db.plans.update_many({"user_id": device_user}, {"$set": {"user_id": account_user}})
        await _db.recipes.update_many({"user_id": device_user}, {"$set": {"user_id": account_user}})
    else:
        if device_user in _profiles and account_user not in _profiles:
            _profiles[account_user] = _profiles[device_user]
        for d in list(_plans.values()) + list(_recipes.values()):
            if d["user_id"] == device_user:
                d["user_id"] = account_user


# ---- plans -----------------------------------------------------------------

async def save_plan(user_id: str, name: str, plan: dict) -> dict:
    doc = {"_id": uuid.uuid4().hex, "user_id": user_id, "name": name, "created_at": _now(), "plan": plan}
    if _db is not None:
        await _db.plans.insert_one(doc)
    else:
        _plans[doc["_id"]] = doc
    return doc


async def list_plans(user_id: str) -> List[dict]:
    if _db is not None:
        cur = _db.plans.find({"user_id": user_id}, {"plan.total_cost": 1, "plan.meals_planned": 1, "plan.meals_required": 1, "name": 1, "created_at": 1}).sort("created_at", -1)
        return [d async for d in cur]
    return sorted([d for d in _plans.values() if d["user_id"] == user_id], key=lambda d: d["created_at"], reverse=True)


async def get_plan(user_id: str, plan_id: str) -> Optional[dict]:
    if _db is not None:
        return await _db.plans.find_one({"_id": plan_id, "user_id": user_id})
    d = _plans.get(plan_id)
    return d if d and d["user_id"] == user_id else None


async def delete_plan(user_id: str, plan_id: str) -> bool:
    if _db is not None:
        r = await _db.plans.delete_one({"_id": plan_id, "user_id": user_id})
        return r.deleted_count == 1
    d = _plans.get(plan_id)
    if d and d["user_id"] == user_id:
        del _plans[plan_id]
        return True
    return False


# ---- recipes ---------------------------------------------------------------

async def save_recipe(user_id: str, recipe: dict, custom_ingredients: List[dict]) -> dict:
    doc = {"_id": recipe["id"], "user_id": user_id, "created_at": _now(), "recipe": recipe, "custom_ingredients": custom_ingredients}
    if _db is not None:
        await _db.recipes.replace_one({"_id": doc["_id"]}, doc, upsert=True)
    else:
        _recipes[doc["_id"]] = doc
    return doc


async def list_recipes(user_id: str) -> List[dict]:
    if _db is not None:
        cur = _db.recipes.find({"user_id": user_id}).sort("created_at", -1)
        return [d async for d in cur]
    return sorted([d for d in _recipes.values() if d["user_id"] == user_id], key=lambda d: d["created_at"], reverse=True)


async def delete_recipe(user_id: str, recipe_id: str) -> bool:
    if _db is not None:
        r = await _db.recipes.delete_one({"_id": recipe_id, "user_id": user_id})
        return r.deleted_count == 1
    d = _recipes.get(recipe_id)
    if d and d["user_id"] == user_id:
        del _recipes[recipe_id]
        return True
    return False
