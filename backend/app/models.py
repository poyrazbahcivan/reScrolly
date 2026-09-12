import re
from typing import List, Optional
from pydantic import BaseModel, Field, field_validator

EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class SkipSlot(BaseModel):
    day: int = Field(ge=0, le=13)
    slot: str
    reason: str = ""


class PlanRequestModel(BaseModel):
    budget: float = Field(40, ge=5, le=1000)
    cook_sessions: int = Field(2, ge=1, le=7)
    days: int = Field(7, ge=1, le=14)
    meals_per_day: int = Field(2, ge=1, le=3)
    exclude_tags: List[str] = []
    exclude_ingredients: List[str] = []
    equipment: List[str] = ["stove", "pan", "pot", "microwave"]
    max_active_minutes_per_session: int = Field(90, ge=20, le=240)
    assume_staples: bool = True
    servings: int = Field(1, ge=1, le=8)
    start_weekday: int = Field(0, ge=0, le=6)
    skip_slots: List[SkipSlot] = []
    must_have: List[str] = []
    likes: List[str] = []
    pinned_recipe_ids: List[str] = []
    only_my_recipes: bool = False
    goals: List[str] = []


class SavePlanModel(BaseModel):
    name: str = "My week"
    plan: dict


class RegisterModel(BaseModel):
    email: str
    password: str = Field(min_length=8, max_length=128)
    name: str = Field(default="", max_length=80)
    device_id: Optional[str] = None

    @field_validator("email")
    @classmethod
    def _email(cls, v: str) -> str:
        v = v.strip().lower()
        if not EMAIL.match(v):
            raise ValueError("Enter a valid email address")
        return v


class LoginModel(BaseModel):
    email: str
    password: str
    device_id: Optional[str] = None

    @field_validator("email")
    @classmethod
    def _email(cls, v: str) -> str:
        return v.strip().lower()


class ForgotModel(BaseModel):
    email: str


class ProfileModel(BaseModel):
    """The quiz answers. Stored as given; the app maps them to a PlanRequest."""
    name: str = ""
    goals: List[str] = []
    servings: int = Field(1, ge=1, le=8)
    diet_style: str = "everything"
    avoid: List[str] = []
    wont_eat: List[str] = []
    must_have: List[str] = []
    likes: List[str] = []
    cooking_level: str = "some"
    equipment: List[str] = []
    budget: float = 40
    cook_sessions: int = 2
    meals_per_day: int = 2
    shop_weekday: int = Field(0, ge=0, le=6)
    use_calendar: bool = False
    notifications: bool = False
    only_my_recipes: bool = False
    onboarding_complete: bool = False


class ImportRecipeModel(BaseModel):
    source: str = Field(pattern="^(url|text|ocr|image)$")
    url: str = Field("", max_length=2048)
    text: str = Field("", max_length=30000)
    hint: str = Field("", max_length=200)
    images: List[str] = Field(default_factory=list, max_length=4)   # base64 JPEG/PNG/WebP/HEIC, one per page

    @field_validator("images")
    @classmethod
    def _images(cls, v: List[str]) -> List[str]:
        if any(len(s) > 11_000_000 for s in v):
            raise ValueError("One of the photos is too large")
        return v


class SaveRecipeModel(BaseModel):
    recipe: dict
    custom_ingredients: List[dict] = []


class FitRecipeModel(BaseModel):
    """An imported recipe, not saved yet, and the week it would join."""
    request: PlanRequestModel
    recipe: dict
    custom_ingredients: List[dict] = []


class TTSModel(BaseModel):
    text: str = Field(max_length=800)
