"""
reScrolly planning engine.

Recipes form a graph: a recipe consumes ingredients and components and
produces components that later recipes consume. The planner chooses recipes
that cover the required meal slots under a budget and a cook-session limit,
minimising cost and distinct ingredients, then schedules them so producers
come before consumers, perishables are used inside their shelf life,
components inside their keeps window, and sessions inside their minute cap.

Inputs the quiz supplies on top of that:
  servings           quantities scale, cost scales, meals are household meals
  skip_slots         meal slots the calendar says are taken; not planned for
  must_have          ingredient ids the week must include if at all possible
  likes              mood tags that earn a scoring bonus
  pinned_recipe_ids  recipes forced into the week (usually the user's own)
  only_my_recipes    restrict the candidate pool to the user's recipes
  extra_recipes      the user's recipe library, same schema as the catalog
  extra_ingredients  custom ingredients those recipes introduced

Search: greedy weighted set cover with chain lookahead, then local search.
Deterministic for a given input. No language model anywhere in here.
"""

from __future__ import annotations

import copy
import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

DATA = Path(__file__).parent / "data"

DAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
SESSION_DAYS = {1: [0], 2: [0, 3], 3: [0, 2, 4], 4: [0, 2, 4, 6], 5: [0, 1, 3, 4, 6], 6: [0, 1, 2, 3, 4, 5], 7: [0, 1, 2, 3, 4, 5, 6]}
SLOTS = {1: ["dinner"], 2: ["lunch", "dinner"], 3: ["breakfast", "lunch", "dinner"]}

INGREDIENT_WEIGHT = 0.55
CHAIN_BONUS = 1.25
MUST_HAVE_BONUS = 1.45
LIKE_BONUS = 0.3    # per matching mood
PREFERENCE_DOLLARS = 3.0   # what a dish you'd prefer is worth per meal, weighed against cost


# ---------------------------------------------------------------- data ----

@dataclass
class Ingredient:
    id: str
    name: str
    pack_qty: float
    unit: str
    pack_price: float
    shelf_life_days: int
    perishable: bool
    section: str
    tags: List[str]
    staple: bool = False


@dataclass
class Component:
    id: str
    name: str
    unit: str
    keeps_days: int


@dataclass
class Recipe:
    id: str
    name: str
    meals: int
    active_minutes: int
    total_minutes: int
    keeps_days: int
    ingredients: List[Tuple[str, float]]
    consumes: List[Tuple[str, float]]
    produces: List[Tuple[str, float]]
    equipment: List[str]
    techniques: List[str]
    tags: List[str]
    steps: List[str]
    moods: List[str] = field(default_factory=list)
    source: str = "catalog"


def _recipe_from_dict(r: dict) -> Recipe:
    return Recipe(
        id=r["id"], name=r["name"], meals=int(r.get("meals", 2)),
        active_minutes=int(r.get("active_minutes", 20)), total_minutes=int(r.get("total_minutes", 30)),
        keeps_days=int(r.get("keeps_days", 3)),
        ingredients=[(x["id"], float(x["qty"])) for x in r.get("ingredients", [])],
        consumes=[(x["id"], float(x["qty"])) for x in r.get("consumes", [])],
        produces=[(x["id"], float(x["qty"])) for x in r.get("produces", [])],
        equipment=list(r.get("equipment", [])), techniques=list(r.get("techniques", [])),
        tags=list(r.get("tags", [])), steps=list(r.get("steps", [])),
        moods=list(r.get("moods", [])), source=r.get("source", "catalog"),
    )


def _ingredient_from_dict(i: dict) -> Ingredient:
    return Ingredient(
        id=i["id"], name=i["name"], pack_qty=float(i.get("pack_qty", 1)), unit=i.get("unit", "ea"),
        pack_price=float(i.get("pack_price", 3.0)), shelf_life_days=int(i.get("shelf_life_days", 7)),
        perishable=bool(i.get("perishable", True)), section=i.get("section", "Other"),
        tags=list(i.get("tags", [])), staple=bool(i.get("staple", False)),
    )


class Catalog:
    def __init__(self, ingredients: Dict[str, Ingredient], components: Dict[str, Component], recipes: Dict[str, Recipe]) -> None:
        self.ingredients = ingredients
        self.components = components
        self.recipes = recipes

    @classmethod
    def load(cls) -> "Catalog":
        ing_raw = json.loads((DATA / "ingredients.json").read_text())
        rec_raw = json.loads((DATA / "recipes.json").read_text())
        return cls(
            {i["id"]: _ingredient_from_dict(i) for i in ing_raw},
            {c["id"]: Component(**c) for c in rec_raw["components"]},
            {r["id"]: _recipe_from_dict(r) for r in rec_raw["recipes"]},
        )

    def extended(self, extra_recipes: List[dict], extra_ingredients: List[dict]) -> "Catalog":
        """A copy with the user's recipes and custom ingredients merged in."""
        ings = dict(self.ingredients)
        for i in extra_ingredients:
            ings[i["id"]] = _ingredient_from_dict(i)
        recs = dict(self.recipes)
        for r in extra_recipes:
            rr = _recipe_from_dict(r)
            rr.source = r.get("source", "mine")
            rr.ingredients = [(i, q) for i, q in rr.ingredients if i in ings]
            recs[rr.id] = rr
        return Catalog(ings, self.components, recs)

    def recipe_dict(self, r: Recipe) -> dict:
        return {
            "id": r.id, "name": r.name, "meals": r.meals, "source": r.source, "moods": r.moods,
            "active_minutes": r.active_minutes, "total_minutes": r.total_minutes, "keeps_days": r.keeps_days,
            "ingredients": [{"id": i, "name": self.ingredients[i].name, "qty": q, "unit": self.ingredients[i].unit} for i, q in r.ingredients if i in self.ingredients],
            "consumes": [{"id": c, "name": self.components[c].name, "qty": q, "unit": self.components[c].unit} for c, q in r.consumes],
            "produces": [{"id": c, "name": self.components[c].name, "qty": q, "unit": self.components[c].unit} for c, q in r.produces],
            "equipment": r.equipment, "techniques": r.techniques, "tags": r.tags, "steps": r.steps,
        }

    def recipe_dicts(self) -> List[dict]:
        return [self.recipe_dict(r) for r in self.recipes.values()]


CATALOG = Catalog.load()


# ------------------------------------------------------------- request ----

@dataclass
class PlanRequest:
    budget: float = 40.0
    cook_sessions: int = 2
    days: int = 7
    meals_per_day: int = 2
    exclude_tags: List[str] = field(default_factory=list)
    exclude_ingredients: List[str] = field(default_factory=list)
    equipment: List[str] = field(default_factory=lambda: ["stove", "pan", "pot", "microwave"])
    max_active_minutes_per_session: int = 90
    assume_staples: bool = True
    servings: int = 1
    start_weekday: int = 0
    skip_slots: List[dict] = field(default_factory=list)
    must_have: List[str] = field(default_factory=list)
    likes: List[str] = field(default_factory=list)
    pinned_recipe_ids: List[str] = field(default_factory=list)
    only_my_recipes: bool = False
    goals: List[str] = field(default_factory=list)   # save | waste | health | learn
    extra_recipes: List[dict] = field(default_factory=list)
    extra_ingredients: List[dict] = field(default_factory=list)

    def day_label(self, day: int) -> str:
        return DAY_NAMES[(self.start_weekday + day) % 7]


# -------------------------------------------------------------- helpers ----

def allowed_recipes(cat: Catalog, req: PlanRequest) -> Dict[str, Recipe]:
    ex_tags = set(req.exclude_tags)
    ex_ing = set(req.exclude_ingredients)
    equip = set(req.equipment)
    out = {}
    for r in cat.recipes.values():
        if req.only_my_recipes and r.source == "catalog" and r.id not in req.pinned_recipe_ids:
            continue
        if ex_tags & set(r.tags):
            continue
        if any(i in ex_ing for i, _ in r.ingredients):
            continue
        if any(ex_tags & set(cat.ingredients[i].tags) for i, _ in r.ingredients if i in cat.ingredients):
            continue
        if r.equipment and not set(r.equipment) <= equip:
            continue
        out[r.id] = r
    return out


def cart(cat: Catalog, selected: Set[str], servings: int = 1) -> Dict[str, float]:
    need: Dict[str, float] = {}
    for rid in selected:
        for i, q in cat.recipes[rid].ingredients:
            need[i] = need.get(i, 0.0) + q * servings
    return need


def cart_cost(cat: Catalog, need: Dict[str, float], assume_staples: bool = True) -> float:
    total = 0.0
    for i, q in need.items():
        ing = cat.ingredients[i]
        if assume_staples and ing.staple:
            continue
        total += math.ceil(q / ing.pack_qty) * ing.pack_price
    return round(total, 2)


def component_balance(cat: Catalog, selected: Set[str]) -> Dict[str, float]:
    bal: Dict[str, float] = {c: 0.0 for c in cat.components}
    for rid in selected:
        r = cat.recipes[rid]
        for c, q in r.produces:
            bal[c] = bal.get(c, 0.0) + q
        for c, q in r.consumes:
            bal[c] = bal.get(c, 0.0) - q
    return bal


def meals_of(cat: Catalog, selected: Set[str]) -> int:
    return sum(cat.recipes[r].meals for r in selected)


def active_of(cat: Catalog, selected: Set[str]) -> int:
    return sum(cat.recipes[r].active_minutes for r in selected)


def is_breakfast(r: Recipe) -> bool:
    return "breakfast" in r.moods


def demand(req: PlanRequest) -> Tuple[int, int]:
    """Open slots that need a meal: (breakfasts, lunches and dinners)."""
    open_slots = [s for s in slot_list(req) if not s["skipped"]]
    b = sum(1 for s in open_slots if s["slot"] == "breakfast")
    return b, len(open_slots) - b


def covered(cat: Catalog, selected: Set[str], req: PlanRequest) -> int:
    """Meals the selection can actually serve. Breakfast food only covers breakfasts, and
    nothing else does: nobody wants biryani at 8 am or pancakes for dinner."""
    need_b, need_m = demand(req)
    b = sum(cat.recipes[r].meals for r in selected if is_breakfast(cat.recipes[r]))
    m = sum(cat.recipes[r].meals for r in selected if not is_breakfast(cat.recipes[r]))
    return min(b, need_b) + min(m, need_m)


def tuning(req: PlanRequest) -> Dict[str, float]:
    """How the answers to "What do you want out of this?" weigh each choice."""
    g = set(req.goals)
    return {
        "cost": 1.5 if "save" in g else 1.0,                                    # every extra dollar counts more
        "ingredient": INGREDIENT_WEIGHT * (1.8 if "waste" in g else 1.0),      # fewer distinct things to buy
        "chain": CHAIN_BONUS * (1.2 if "waste" in g else 1.0),                  # more cook-once, eat-twice
    }


def slot_list(req: PlanRequest) -> List[dict]:
    """Every meal slot in the week, with calendar skips marked."""
    slots = SLOTS[max(1, min(3, req.meals_per_day))]
    skips = {(int(s["day"]), s["slot"]): s.get("reason", "") for s in req.skip_slots}
    out = []
    for day in range(req.days):
        for slot in slots:
            reason = skips.get((day, slot))
            out.append({"day": day, "slot": slot, "skipped": reason is not None, "reason": reason or ""})
    return out


def expand(cat: Catalog, allowed: Dict[str, Recipe], selected: Set[str], rid: str, req: PlanRequest, depth: int = 0) -> Optional[Set[str]]:
    """Recipes to add so that `rid` has its components covered."""
    if depth > 3:
        return None
    add = {rid}
    bal = component_balance(cat, selected | add)
    for c, _ in cat.recipes[rid].consumes:
        if bal.get(c, 0) >= -1e-9:
            continue
        producers = [p for p in allowed.values() if any(pc == c for pc, _ in p.produces) and p.id not in selected and p.id not in add]
        if not producers:
            return None
        best, best_cost = None, float("inf")
        base = cart_cost(cat, cart(cat, selected | add, req.servings), req.assume_staples)
        for p in sorted(producers, key=lambda x: x.id):
            sub = expand(cat, allowed, selected | add, p.id, req, depth + 1)
            if sub is None:
                continue
            cost = cart_cost(cat, cart(cat, selected | add | sub, req.servings), req.assume_staples) - base
            if cost < best_cost:
                best, best_cost = sub, cost
        if best is None:
            return None
        add |= best
        bal = component_balance(cat, selected | add)
        if bal.get(c, 0) < -1e-9:
            return None
    return add


def feasible(cat: Catalog, req: PlanRequest, selected: Set[str]) -> bool:
    bal = component_balance(cat, selected)
    if any(v < -1e-9 for v in bal.values()):
        return False
    if active_of(cat, selected) > req.cook_sessions * req.max_active_minutes_per_session:
        return False
    return True


def preference_multiplier(r: Recipe, req: PlanRequest) -> float:
    m = 1.0
    if req.must_have and any(i in req.must_have for i, _ in r.ingredients):
        m *= MUST_HAVE_BONUS
    if req.likes:
        m *= 1.0 + LIKE_BONUS * len(set(r.moods) & set(req.likes))
    if "health" in req.goals:
        m *= 1.0 + 0.3 * len(set(r.moods) & {"light", "high_fiber", "high_protein"})
    if "learn" in req.goals:
        m *= 1.0 + 0.15 * min(3, len(set(r.techniques)))
    if r.source != "catalog":
        m *= 1.2   # the user's own recipes get a nudge
    return m


def bundle(cat: Catalog, allowed: Dict[str, Recipe], req: PlanRequest, selected: Set[str], add: Set[str], required: int) -> Set[str]:
    base_need = cart(cat, selected, req.servings)
    base_cost = cart_cost(cat, base_need, req.assume_staples)
    base_ing = set(base_need)
    base_cov = covered(cat, selected, req)
    t = tuning(req)

    def score_of(add_set: Set[str]) -> Tuple[float, float]:
        sel = selected | add_set
        need = cart(cat, sel, req.servings)
        cost = cart_cost(cat, need, req.assume_staples)
        new_ing = len({x for x in set(need) - base_ing if not cat.ingredients[x].staple})
        meals = covered(cat, sel, req) - base_cov
        pref = max((preference_multiplier(cat.recipes[x], req) for x in add_set), default=1.0)
        return pref * meals / (t["cost"] * (cost - base_cost) + t["ingredient"] * new_ing + 0.01), cost

    cur_score, _ = score_of(add)
    changed = True
    while changed:
        changed = False
        if covered(cat, selected | add, req) >= required:
            break
        produced = {c for x in add for c, _ in cat.recipes[x].produces}
        best, best_score = None, cur_score
        for cand in sorted(allowed.values(), key=lambda x: x.id):
            if cand.id in selected or cand.id in add or cand.meals == 0:
                continue
            if not any(c in produced for c, _ in cand.consumes):
                continue
            sub = expand(cat, allowed, selected | add, cand.id, req)
            if sub is None:
                continue
            trial = add | sub
            if not feasible(cat, req, selected | trial):
                continue
            sc, cost = score_of(trial)
            if cost > req.budget + 1e-9:
                continue
            if sc > best_score:
                best, best_score = trial, sc
        if best is not None:
            add, cur_score, changed = best, best_score, True
    return add


# --------------------------------------------------------------- select ----

def select_recipes(cat: Catalog, req: PlanRequest, required: int) -> Tuple[Set[str], List[str]]:
    allowed = allowed_recipes(cat, req)
    selected: Set[str] = set()
    notes: List[str] = []

    # pinned recipes go in first, budget permitting
    for pid in req.pinned_recipe_ids:
        if pid not in allowed:
            if pid in cat.recipes:
                notes.append(f"{cat.recipes[pid].name} was pinned but conflicts with your limits, so it was left out.")
            continue
        add = expand(cat, allowed, selected, pid, req)
        if add is None or not feasible(cat, req, selected | add):
            notes.append(f"{cat.recipes[pid].name} was pinned but doesn't fit the session cap.")
            continue
        selected |= add
    if cart_cost(cat, cart(cat, selected, req.servings), req.assume_staples) > req.budget:
        notes.append("Your pinned recipes alone are over budget.")

    t = tuning(req)
    while covered(cat, selected, req) < required:
        base_cov = covered(cat, selected, req)
        base_need = cart(cat, selected, req.servings)
        base_cost = cart_cost(cat, base_need, req.assume_staples)
        base_ing = set(base_need)
        bal = component_balance(cat, selected)
        best, best_score = None, -1.0

        for r in sorted(allowed.values(), key=lambda x: x.id):
            if r.id in selected or r.meals == 0:
                continue
            add = expand(cat, allowed, selected, r.id, req)
            if add is None:
                continue
            add = bundle(cat, allowed, req, selected, add, required)
            new_sel = selected | add
            if not feasible(cat, req, new_sel):
                continue
            new_need = cart(cat, new_sel, req.servings)
            new_cost = cart_cost(cat, new_need, req.assume_staples)
            if new_cost > req.budget + 1e-9:
                continue
            meals_delta = covered(cat, new_sel, req) - base_cov
            if meals_delta <= 0:
                continue
            new_ing = len({x for x in set(new_need) - base_ing if not cat.ingredients[x].staple})
            score = meals_delta / (t["cost"] * (new_cost - base_cost) + t["ingredient"] * new_ing + 0.01)
            score *= preference_multiplier(r, req)
            if any(bal.get(c, 0) >= q for c, q in r.consumes):
                score *= t["chain"]
            if score > best_score:
                best, best_score = add, score

        if best is None:
            notes.append("Budget or constraints stopped the plan before every meal was covered.")
            break
        selected |= best

    selected = ensure_must_have(cat, allowed, req, selected)
    selected = local_search(cat, req, allowed, selected, required)
    return selected, notes


def ensure_must_have(cat: Catalog, allowed: Dict[str, Recipe], req: PlanRequest, selected: Set[str]) -> Set[str]:
    """If a must-have ingredient is missing, add the cheapest recipe that uses it, inside budget."""
    for ing in req.must_have:
        if any(any(i == ing for i, _ in cat.recipes[r].ingredients) for r in selected):
            continue
        best, best_cost = None, float("inf")
        for r in allowed.values():
            if r.id in selected or not any(i == ing for i, _ in r.ingredients):
                continue
            add = expand(cat, allowed, selected, r.id, req)
            if add is None or not feasible(cat, req, selected | add):
                continue
            cost = cart_cost(cat, cart(cat, selected | add, req.servings), req.assume_staples)
            if cost <= req.budget and cost < best_cost:
                best, best_cost = add, cost
        if best:
            selected = selected | best
    return selected


def week_value(cat: Catalog, req: PlanRequest, sel: Set[str]) -> Tuple[float, float]:
    """(value, cost). Lower value is better: cost and distinct ingredients, less what the dishes you'd prefer are worth.
    Without this the cleanup pass would swap every preferred dish for the cheapest one and undo the answers."""
    t = tuning(req)
    need = cart(cat, sel, req.servings)
    cost = cart_cost(cat, need, req.assume_staples)
    distinct = len([x for x in need if not cat.ingredients[x].staple])
    pref = sum((preference_multiplier(cat.recipes[r], req) - 1.0) * cat.recipes[r].meals for r in sel)
    value = t["cost"] * cost + t["ingredient"] * distinct - PREFERENCE_DOLLARS * pref
    if "waste" in req.goals:
        value += 1.5 * waste_estimate(cat, sel, need, req.servings)[0]          # leftover perishables, in dollars
    if "learn" in req.goals:
        value -= 5.0 * len({x for r in sel if cat.recipes[r].meals > 0 for x in cat.recipes[r].techniques})   # more to practise
    return value, cost


def local_search(cat: Catalog, req: PlanRequest, allowed: Dict[str, Recipe], selected: Set[str], required: int) -> Set[str]:
    pinned = set(req.pinned_recipe_ids)
    must_ok = lambda sel: all(any(any(i == ing for i, _ in cat.recipes[r].ingredients) for r in sel) for ing in req.must_have if any(any(i == ing for i, _ in cat.recipes[r].ingredients) for r in selected))
    target = min(required, covered(cat, selected, req))

    def served(sel: Set[str]) -> int:
        """Meals the week can really serve once cook days and keep-by days are applied, not just portions on paper."""
        sessions, session_of, _ = schedule(cat, req, sel)
        return required - assign_meals(cat, req, sel, sessions, session_of)[1]

    floor = served(selected)
    improved, rounds = True, 0
    while improved and rounds < 20:
        improved = False
        rounds += 1
        cur_val, _ = week_value(cat, req, selected)
        for rid in sorted(selected):
            if rid in pinned:
                continue
            trial = selected - {rid}
            if covered(cat, trial, req) >= target and feasible(cat, req, trial) and must_ok(trial):
                if week_value(cat, req, trial)[0] < cur_val - 0.01 and served(trial) >= floor:
                    selected, improved = trial, True
                    floor = served(trial)
                    break
        if improved:
            continue
        for rid in sorted(selected):
            if rid in pinned or cat.recipes[rid].meals == 0:
                continue
            for cand in sorted(allowed):
                if cand in selected or cat.recipes[cand].meals == 0:
                    continue
                base = selected - {rid}
                add = expand(cat, allowed, base, cand, req)
                if add is None:
                    continue
                trial = base | add
                if covered(cat, trial, req) < target or not feasible(cat, req, trial) or not must_ok(trial):
                    continue
                v, c = week_value(cat, req, trial)
                if v < cur_val - 0.01 and c <= req.budget and served(trial) >= floor:
                    selected, improved = trial, True
                    floor = served(trial)
                    break
            if improved:
                break
    return selected


# ------------------------------------------------------------- schedule ----

def topo_order(cat: Catalog, selected: Set[str]):
    producers_of: Dict[str, List[str]] = {}
    for rid in selected:
        for c, _ in cat.recipes[rid].produces:
            producers_of.setdefault(c, []).append(rid)
    deps: Dict[str, Set[str]] = {rid: set() for rid in selected}
    for rid in selected:
        for c, _ in cat.recipes[rid].consumes:
            for p in producers_of.get(c, []):
                if p != rid:
                    deps[rid].add(p)
    order: List[str] = []
    remaining = set(selected)
    while remaining:
        ready = sorted(r for r in remaining if deps[r] <= set(order)) or sorted(remaining)
        ready.sort(key=lambda r: (min([cat.ingredients[i].shelf_life_days for i, _ in cat.recipes[r].ingredients if cat.ingredients[i].perishable] or [99]), -len(cat.recipes[r].produces)))
        order.append(ready[0])
        remaining.remove(ready[0])
    return order, deps


def schedule(cat: Catalog, req: PlanRequest, selected: Set[str]):
    days = SESSION_DAYS[max(1, min(7, req.cook_sessions))]
    cap = req.max_active_minutes_per_session
    load = [0] * len(days)
    portion_load = [0] * len(days)
    session_of: Dict[str, int] = {}
    warnings: List[str] = []
    order, deps = topo_order(cat, selected)

    for rid in order:
        r = cat.recipes[rid]
        earliest = max([session_of[d] for d in deps[rid]] or [0])
        latest_day = min([cat.ingredients[i].shelf_life_days for i, _ in r.ingredients if cat.ingredients[i].perishable] or [99])
        for d in deps[rid]:
            for c, _ in cat.recipes[d].produces:
                if any(c == cc for cc, _ in r.consumes):
                    latest_day = min(latest_day, days[session_of[d]] + cat.components[c].keeps_days)
        options = [s for s in range(earliest, len(days)) if days[s] <= latest_day and load[s] + r.active_minutes <= cap]
        placed = None
        if options:
            placed = options[0] if r.meals == 0 else min(options, key=lambda s: (portion_load[s], s))
        if placed is None:
            candidates = [s for s in range(earliest, len(days)) if days[s] <= latest_day] or list(range(earliest, len(days)))
            placed = min(candidates, key=lambda s: load[s])
            if load[placed] + r.active_minutes > cap:
                warnings.append(f"{req.day_label(days[placed])} runs over the {cap}-minute session cap by {load[placed] + r.active_minutes - cap} minutes.")
        session_of[rid] = placed
        load[placed] += r.active_minutes
        portion_load[placed] += r.meals

    sessions = []
    for s, day in enumerate(days):
        rids = [rid for rid in order if session_of[rid] == s]
        sessions.append({"index": s, "day": day, "label": req.day_label(day), "recipe_ids": rids,
                         "active_minutes": load[s], "total_minutes": sum(cat.recipes[x].total_minutes for x in rids)})
    return sessions, session_of, warnings


def assign_meals(cat: Catalog, req: PlanRequest, selected: Set[str], sessions: List[dict], session_of: Dict[str, int]):
    """Portions into slots. Breakfast slots take breakfast food and nothing else does.
    First every slot takes the portion that spoils soonest, which covers the most meals possible.
    Then portions are swapped between days, only where both stay inside their keep-by day, until
    lunch and dinner are different dishes and back-to-back meals differ wherever the week allows."""
    portions = []   # (last day it's good, first day it's ready, recipe id)
    for rid in selected:
        r = cat.recipes[rid]
        day = sessions[session_of[rid]]["day"]
        portions += [(day + r.keeps_days, day, rid) for _ in range(r.meals)]
    meals: List[dict] = []
    got: List[Optional[tuple]] = []
    unfilled = 0
    for s in slot_list(req):
        base = {"day": s["day"], "label": req.day_label(s["day"]), "slot": s["slot"], "recipe_id": None, "from_session": None,
                "skipped": s["skipped"], "reason": s["reason"]}
        breakfast = s["slot"] == "breakfast"
        avail = [] if s["skipped"] else [p for p in portions if p[1] <= s["day"] <= p[0] and is_breakfast(cat.recipes[p[2]]) == breakfast]
        if not avail:
            unfilled += 0 if s["skipped"] else 1
            meals.append(base)
            got.append(None)
            continue
        p = min(avail, key=lambda p: (p[0], p[2]))
        portions.remove(p)
        meals.append({**base, "recipe_id": p[2], "from_session": session_of[p[2]]})
        got.append(p)

    def clashes() -> int:
        ids = [m["recipe_id"] for m in meals]
        n = sum(1 for i in range(1, len(ids)) if ids[i] and ids[i] == ids[i - 1])          # back to back
        per_day: Dict[int, List[str]] = {}
        for m in meals:
            if m["recipe_id"]:
                per_day.setdefault(m["day"], []).append(m["recipe_id"])
        return n + 3 * sum(len(v) - len(set(v)) for v in per_day.values())                   # twice in one day

    def swap(i: int, j: int) -> None:
        got[i], got[j] = got[j], got[i]
        for k in (i, j):
            rid = got[k][2]
            meals[k]["recipe_id"], meals[k]["from_session"] = rid, session_of[rid]

    current = clashes()
    for _ in range(60):
        if current == 0:
            break
        best = None
        for i in range(len(meals)):
            for j in range(i + 1, len(meals)):
                pi, pj = got[i], got[j]
                if pi is None or pj is None or pi[2] == pj[2] or (meals[i]["slot"] == "breakfast") != (meals[j]["slot"] == "breakfast"):
                    continue
                di, dj = meals[i]["day"], meals[j]["day"]
                if not (pj[1] <= di <= pj[0] and pi[1] <= dj <= pi[0]):
                    continue
                swap(i, j)
                after = clashes()
                swap(i, j)
                if after < current and (best is None or after < best[0]):
                    best = (after, i, j)
        if best is None:
            break
        swap(best[1], best[2])
        current = best[0]
    return meals, unfilled


# --------------------------------------------------------------- report ----

SECTION_ORDER = ["Produce", "Meat", "Seafood", "Dairy & Eggs", "Bakery", "Frozen", "Pantry", "Other", "Check your pantry"]


def shopping_list(cat: Catalog, need: Dict[str, float], assume_staples: bool = True) -> List[dict]:
    rows = []
    for i, q in need.items():
        ing = cat.ingredients[i]
        packs = math.ceil(q / ing.pack_qty)
        rows.append({"id": i, "name": ing.name, "section": ing.section, "qty_needed": round(q, 1), "unit": ing.unit,
                     "packs": packs, "pack_qty": ing.pack_qty, "pack_price": ing.pack_price,
                     "cost": round(packs * ing.pack_price, 2), "perishable": ing.perishable, "staple": ing.staple})
    if assume_staples:
        for r in rows:
            if r["staple"]:
                r["section"] = "Check your pantry"
                r["cost"] = 0.0
    rows.sort(key=lambda r: (SECTION_ORDER.index(r["section"]) if r["section"] in SECTION_ORDER else 98, r["name"]))
    return rows


def perishables_report(cat, selected, need, sessions, session_of) -> List[dict]:
    out = []
    for i in need:
        ing = cat.ingredients[i]
        if not ing.perishable:
            continue
        users = [rid for rid in selected if any(x == i for x, _ in cat.recipes[rid].ingredients)]
        last = max(sessions[session_of[rid]]["day"] for rid in users)
        out.append({"id": i, "name": ing.name, "shelf_life_days": ing.shelf_life_days, "last_used_day": last, "ok": last <= ing.shelf_life_days})
    out.sort(key=lambda r: r["shelf_life_days"])
    return out


def waste_estimate(cat, selected, need, servings) -> Tuple[float, float]:
    plan, baseline = 0.0, 0.0
    for i, q in need.items():
        ing = cat.ingredients[i]
        if not ing.perishable:
            continue
        packs = math.ceil(q / ing.pack_qty)
        plan += ((packs * ing.pack_qty - q) / ing.pack_qty) * ing.pack_price
        for rid in selected:
            for x, rq in cat.recipes[rid].ingredients:
                if x == i:
                    per = math.ceil(rq * servings / ing.pack_qty)
                    baseline += ((per * ing.pack_qty - rq * servings) / ing.pack_qty) * ing.pack_price
    return round(plan, 2), round(baseline, 2)


def build_graph(cat, selected, session_of, need) -> dict:
    nodes, edges = [], []
    for i in need:
        nodes.append({"id": f"ing:{i}", "kind": "ingredient", "label": cat.ingredients[i].name, "session": None})
    for rid in selected:
        r = cat.recipes[rid]
        nodes.append({"id": f"rec:{rid}", "kind": "recipe", "label": r.name, "session": session_of[rid], "meals": r.meals})
        for i, _ in r.ingredients:
            edges.append({"from": f"ing:{i}", "to": f"rec:{rid}", "label": ""})
    producers: Dict[str, List[str]] = {}
    for rid in selected:
        for c, _ in cat.recipes[rid].produces:
            producers.setdefault(c, []).append(rid)
    for rid in selected:
        for c, _ in cat.recipes[rid].consumes:
            for p in producers.get(c, []):
                edges.append({"from": f"rec:{p}", "to": f"rec:{rid}", "label": cat.components[c].name})
    return {"nodes": nodes, "edges": edges}


def explanations(cat, req, selected, sessions, session_of, perish, total, meals) -> List[str]:
    out = [f"Total ${total:.2f} of your ${req.budget:.0f} budget" + (f", for {req.servings} people." if req.servings > 1 else ".")]
    mine = [cat.recipes[r].name for r in selected if cat.recipes[r].source != "catalog"]
    if mine:
        out.append("Your recipes in this week: " + ", ".join(mine) + ".")
    skipped = [m for m in meals if m["skipped"]]
    if skipped:
        out.append(f"{len(skipped)} meal{'s' if len(skipped) != 1 else ''} left open for plans on your calendar.")
    for ing in req.must_have:
        if any(any(i == ing for i, _ in cat.recipes[r].ingredients) for r in selected) and ing in cat.ingredients:
            out.append(f"{cat.ingredients[ing].name} is in, as asked.")
    producers: Dict[str, List[str]] = {}
    for rid in selected:
        for c, _ in cat.recipes[rid].produces:
            producers.setdefault(c, []).append(rid)
    for c, prods in producers.items():
        consumers = [rid for rid in selected if any(cc == c for cc, _ in cat.recipes[rid].consumes)]
        if not consumers:
            continue
        names = ", ".join(cat.recipes[x].name.lower() for x in consumers)
        out.append(f"{cat.components[c].name} from {sessions[session_of[prods[0]]]['label']} goes into {names}.")
    for p in perish:
        if p["shelf_life_days"] <= 5:
            out.append(f"{p['name']} is used by {req.day_label(p['last_used_day'])}, inside its {p['shelf_life_days']}-day window.")
    return out


GOAL_EFFECT = {
    "save": "Every extra dollar weighs 50% more in each choice, so this is the cheapest week that covers your meals.",
    "waste": "Leftover perishables count against a plan, and dishes that reuse an earlier cook are favoured.",
    "health": "Light, high-fibre, and high-protein dishes are favoured.",
    "learn": "Weeks that practise more different techniques are favoured.",
}


def considered(cat: Catalog, req: PlanRequest, selected: Set[str], sessions: List[dict], meals: List[dict], total: float,
               required: int, unfilled: int) -> List[dict]:
    """One line per onboarding answer: what it did to this week, with numbers from the plan itself."""
    out: List[dict] = []
    add = lambda key, effect: out.append({"key": key, "effect": effect})
    pool = [r for r in cat.recipes.values() if r.meals > 0]
    dishes = [cat.recipes[r] for r in selected if cat.recipes[r].meals > 0]
    plural = lambda n, w: f"{n} {w}{'' if n == 1 else 's'}"

    add("servings", f"Every amount and the shopping list are sized for {plural(req.servings, 'person') if req.servings == 1 else f'{req.servings} people'}.")
    ex = set(req.exclude_tags)
    def tags_of(r):
        return set(r.tags) | {t for i, _ in r.ingredients if i in cat.ingredients for t in cat.ingredients[i].tags}
    ruled = [r for r in pool if ex & tags_of(r)]
    add("diet", f"{len(ruled)} of {len(pool)} recipes ruled out, so nothing you avoid can be planned." if ex else f"All {len(pool)} recipes are on the table.")
    if req.exclude_ingredients:
        n = sum(1 for r in pool if any(i in req.exclude_ingredients for i, _ in r.ingredients))
        add("wont_eat", f"{plural(n, 'more recipe')} ruled out for containing them." if n else "None of the recipes use them.")
    for ing in req.must_have:
        if ing not in cat.ingredients:
            continue
        users = [r.name for r in dishes if any(i == ing for i, _ in r.ingredients)]
        add("must_have", f"{cat.ingredients[ing].name}: in " + ", ".join(users) + "." if users else f"{cat.ingredients[ing].name}: couldn't fit it inside your limits this week.")
    if req.likes:
        match = [r.name for r in dishes if set(r.moods) & set(req.likes)]
        add("likes", f"{len(match)} of {len(dishes)} dishes match" + (": " + ", ".join(match[:4]) + "." if match else "."))
    longest = max((s["active_minutes"] for s in sessions), default=0)
    add("skill", f"Each cook is capped at {req.max_active_minutes_per_session} minutes hands-on. Your longest is {longest}.")
    missing = [r for r in pool if r.equipment and not set(r.equipment) <= set(req.equipment)]
    add("kitchen", (f"{plural(len(missing), 'recipe')} {'needs' if len(missing) == 1 else 'need'} equipment you don't have, so "
                    f"{'it is' if len(missing) == 1 else 'they are'} out.") if missing else "Every recipe works with your kitchen.")
    served = required - unfilled
    add("budget", f"${total:.2f} of ${req.budget:.0f}" + (f", about ${total / served:.2f} a meal." if served else "."))
    add("sessions", f"{plural(len(sessions), 'cook')}: " + ", ".join(s["label"] for s in sessions) + ".")
    b_slots = sum(1 for m in meals if m["slot"] == "breakfast" and not m["skipped"])
    add("meals", f"{served} of {required} meals covered" + (f", breakfasts only from breakfast dishes." if b_slots else "."))
    days = {}
    for m in meals:
        if m["recipe_id"] and m["slot"] != "breakfast":
            days.setdefault(m["day"], []).append(m["recipe_id"])
    two = [ids for ids in days.values() if len(ids) >= 2]
    if two:
        add("variety", f"Lunch and dinner are different dishes on {sum(1 for ids in two if len(set(ids)) == len(ids))} of {len(two)} days.")
    for g in req.goals:
        if g in GOAL_EFFECT:
            extra = ""
            if g == "health":
                n = sum(1 for r in dishes if set(r.moods) & {"light", "high_fiber", "high_protein"})
                extra = f" {n} of {len(dishes)} this week."
            elif g == "learn":
                tech = sorted({t for r in dishes for t in r.techniques})
                extra = f" This week practises {len(tech)}: {', '.join(tech)}." if tech else ""
            add(f"goal_{g}", GOAL_EFFECT[g] + extra)
    skipped = sum(1 for m in meals if m["skipped"])
    if req.skip_slots:
        add("calendar", f"{plural(skipped, 'meal')} left open for plans on your calendar.")
    for pid in req.pinned_recipe_ids:
        if pid in cat.recipes:
            add("pinned", f"{cat.recipes[pid].name}: " + ("in the week." if pid in selected else "doesn't fit your limits this week."))
    return out


# ------------------------------------------------------------------ run ----

def _run(req: PlanRequest, cat: Catalog):
    required = sum(1 for s in slot_list(req) if not s["skipped"])
    selected, notes = select_recipes(cat, req, required)
    sessions, session_of, warnings = schedule(cat, req, selected)
    meals, unfilled = assign_meals(cat, req, selected, sessions, session_of)
    return required, selected, notes, sessions, session_of, warnings, meals, unfilled


def budget_to_cover(req: PlanRequest, cat: Catalog, step: float = 2.0, max_extra: float = 30.0) -> Optional[float]:
    extra = 0.0
    while extra <= max_extra:
        trial = PlanRequest(**{**req.__dict__, "budget": req.budget + extra})
        _, sel, _, _, _, _, _, unfilled = _run(trial, cat)
        if unfilled == 0:
            return round(cart_cost(cat, cart(cat, sel, req.servings), req.assume_staples), 2)
        extra += step
    return None


def sessions_to_cover(req: PlanRequest, cat: Catalog) -> Optional[int]:
    for n in range(req.cook_sessions + 1, 5):
        trial = PlanRequest(**{**req.__dict__, "cook_sessions": n})
        if _run(trial, cat)[7] == 0:
            return n
    return None


def plan(req: PlanRequest, base: Catalog = CATALOG) -> dict:
    cat = base.extended(req.extra_recipes, req.extra_ingredients) if (req.extra_recipes or req.extra_ingredients) else base
    required, selected, notes, sessions, session_of, warnings, meals, unfilled = _run(req, cat)
    need = cart(cat, selected, req.servings)
    total = cart_cost(cat, need, req.assume_staples)
    perish = perishables_report(cat, selected, need, sessions, session_of)
    waste_plan, waste_base = waste_estimate(cat, selected, need, req.servings)
    cover_all = None if unfilled == 0 else budget_to_cover(req, cat)
    sessions_needed = None if (unfilled == 0 or cover_all is not None) else sessions_to_cover(req, cat)

    recipes = []
    for rid in sorted(selected, key=lambda x: (session_of[x], x)):
        d = cat.recipe_dict(cat.recipes[rid])
        d["session"] = session_of[rid]
        d["pinned"] = rid in req.pinned_recipe_ids
        recipes.append(d)

    public_req = {k: v for k, v in req.__dict__.items() if k not in ("extra_recipes", "extra_ingredients")}
    return {
        "request": public_req,
        "meals_required": required,
        "meals_planned": required - unfilled,
        "meals_unfilled": unfilled,
        "meals_skipped": sum(1 for m in meals if m["skipped"]),
        "budget_to_cover_all": cover_all,
        "sessions_to_cover_all": sessions_needed,
        "total_cost": total,
        "distinct_ingredients": len([x for x in need if not (req.assume_staples and cat.ingredients[x].staple)]),
        "waste_plan": waste_plan,
        "waste_baseline": waste_base,
        "sessions": sessions,
        "recipes": recipes,
        "meals": meals,
        "shopping": shopping_list(cat, need, req.assume_staples),
        "perishables": perish,
        "graph": build_graph(cat, selected, session_of, need),
        "explanations": explanations(cat, req, selected, sessions, session_of, perish, total, meals),
        "warnings": warnings + notes,
        "considered": considered(cat, req, selected, sessions, meals, total, required, unfilled),
    }
