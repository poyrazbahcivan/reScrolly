# reScrolly

Cook a few times. Eat all week.

You set a budget, how often you'll actually cook, what you won't eat, and what's in your kitchen. You get one shopping trip, a cooking plan where what you cook first becomes what you eat later, and every meal for the week, with nothing rotting in the fridge.

- `backend/` — FastAPI. The planning engine, the recipe graph, accounts and sessions, profiles, saved plans. Optional Auth0 and MongoDB. Runs with zero configuration.
- `ios/` — SwiftUI, iOS 17+. Welcome, ten-step onboarding, login and account creation, five-tab app, profile and settings. Ships with a bundled sample week so the demo works with no network.

## The engine, in one paragraph

Recipes form a graph. A recipe consumes ingredients and *components* (cooked rice, tomato sauce, a chicken carcass) and produces components that later recipes consume. The planner runs greedy weighted set cover with chain lookahead over that graph, choosing recipes that cover the required meals under the budget and the session cap while minimising cost and distinct ingredients. Then it schedules recipes into cook sessions so producers come before consumers, every perishable is used inside its shelf life (shopping is day 0), every component is eaten inside its keeps window, and each session stays inside its active-minute cap. A local search pass tries removals and swaps. Deterministic, under 50 ms.

No language model is anywhere in the decision path. That's deliberate, and it's the answer to "isn't this a wrapper."

---

## App flow

```
Welcome ──► Quiz (15 steps, progress bar, skip on optional) ──► Building ──► Main
   │                                                                    ▲
   └──► Log in ──► (profile on server?) ──────────────────────────────┘
                   (no profile) ──► Quiz
```

Every quiz answer changes the plan. The mapping lives in `AppState.makeRequest()`:

| Question | Effect in the engine |
|---|---|
| Feeding how many | every quantity, pack count, and cost scales |
| Diet style | excludes meat / fish / dairy / egg tags |
| Avoiding (allergens) | hard exclusion by tag |
| Won't eat (ingredients) | hard exclusion by ingredient |
| Must have (ingredients) | scoring bonus, then a guarantee pass; the plan says which made it |
| Likes | scoring bonus by mood tag |
| Cooking level | 60 / 90 / 120 hands-on minutes per session |
| Kitchen | only recipes whose equipment you have |
| Budget | hard cap on the shopping trip |
| Cook frequency | number of sessions and their spacing |
| Meals per day | required slots |
| Shopping day | anchors the weekly reminder |
| Calendar | events that look like lunch or dinner leave that slot open |

**Recipes.** Three ways in, one preview, one Save: paste a link (Instagram post or reel, TikTok, any recipe site), take photos (up to four pages; Gemini reads the photos directly and returns only the fields the planner uses), or type it. The server structures everything with Gemini when a key is set, or a rule-based parser otherwise, maps every ingredient to the price catalog, and invents a priced custom ingredient for anything unmatched. Saved recipes live in the user's library and are always in the planner's candidate pool. **Pin** a recipe and the next plan is forced to include it. **Only plan with my recipes** restricts the pool to the library. The app also opens `onepercentchocolatemilk.rescrolly://import?url=…` straight into the import sheet.

**Calendar.** Read only, on device. Titles and times for the next seven days are checked for lunch and dinner words and social evening events. Matching slots are left open, the reason is shown on Today and Plan, and the plan's meal count drops accordingly. Nothing is uploaded.

**Weekly check-in.** One notification, the evening before shopping day, asking whether anything changed. Permission is requested only when the toggle is turned on.

**Grocery list.** A paper-style sheet grouped by aisle with square checkboxes, quantities, per-item cost, and the total. Share as PDF (rendered from the same view) or copy as text.

Account creation is asked for *after* the first plan is shown, once, and never blocks anything. Guest data, including recipes, migrates to the account.

Main tabs: **Today**, **Plan** (cost against budget, the week with calendar gaps, cook sessions, the chaining graph, the rot timeline, why), **Recipes** (library, add, pin), **Shop** (the paper list), **Profile** (edit any answer and replan, saved weeks, account, privacy, notifications, server).

---

### Share a reel straight into reScrolly

`ios/reScrollyShare/` is a Share Extension (target `reScrollyShare`, embedded in the app). In Instagram: open a reel → **Share** → the iOS share sheet → **reScrolly**. The first time, reScrolly may sit under **More**; tap Edit and move it into the row.

1. The extension pulls the link out of what was shared (a URL, or text containing one for TikTok) and calls `/recipes/import` itself, so the recipe card appears inside Instagram: name, meals, time, ingredients.
2. **Add to my week** opens `onepercentchocolatemilk.rescrolly://import?url=…`. The server cached what it read for 30 minutes, so the app shows the preview instantly.
3. The preview calls `/recipes/fit`, which runs the planner twice, without the recipe and with it pinned, and shows the difference: cost change on the shopping trip, ingredients it shares with what you're already buying, what it replaces, and whether you lose meals under your budget.
4. **Save and plan my week** saves it, pins it, and rebuilds the week around it.

If iOS refuses to open the app from the extension, the link is copied instead and the card says to paste it in Recipes → +.

### How link import works

- **Instagram.** A server that fetches an Instagram page gets HTML with no caption and no `og:` tags, so the page itself is useless. The server asks Instagram's public oEmbed endpoint (`instagram.com/api/v1/oembed/?url=…`) for the caption and cover image, and falls back to the post's `/embed/captioned/` page. Share and `?igsh=` links are normalised to `instagram.com/p/<code>/` first. The caption **and** the cover image go to Gemini, since reels often print the ingredients on the cover. Private posts can't be read, and a recipe that is only spoken in the video isn't in either; the app says so and suggests typing the dish name.
- **TikTok.** Same idea through `tiktok.com/oembed` (caption and cover). Short `vm.tiktok.com` links are resolved first.
- **Recipe sites.** schema.org `Recipe` JSON-LD when present (most sites), otherwise title, description, and the page's visible text.
- **Getting a link into the app.** In Instagram: Share → Copy link → Add a recipe → Paste. Or open `onepercentchocolatemilk.rescrolly://import?url=<encoded link>` from anywhere, for example an iOS Shortcut that accepts URLs from the share sheet, and the import sheet opens with the link filled in.

Gemini is called with a response schema, so the reply is exactly the recipe fields and nothing else. If the model is overloaded it retries on `GEMINI_FALLBACK_MODELS`; text sources then fall back to the rule-based parser.

## Backend

```bash
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env            # set SECRET_KEY to anything long and random
uvicorn app.main:app --reload --port 8000
```

| Method | Path | What |
|---|---|---|
| GET | `/health` | status, whether Auth0 and Mongo are on |
| GET | `/catalog` | recipes, ingredients, components, tags, equipment |
| POST | `/auth/register` | email, password, name, device_id → token. Migrates guest data. |
| POST | `/auth/login` | email, password, device_id → token |
| POST | `/auth/forgot` | always 200; email delivery is out of scope for the event |
| GET | `/auth/me` | who the token belongs to |
| GET / PUT | `/profile` | the quiz answers |
| POST | `/recipes/fit` | recipe + plan request → the week without it vs. with it pinned: cost delta, shared ingredients, replaced recipes |
| POST | `/recipes/import` | link, photos (base64 JPEGs), or text → structured recipe with priced ingredients. Nothing saved. |
| POST / GET | `/recipes` | save to / list the user's library |
| DELETE | `/recipes/{id}` | remove one |
| POST | `/tts` | ElevenLabs text-to-speech, when configured |
| POST | `/plan` | the planner; the caller's saved recipes are merged into the pool |
| POST / GET | `/plans` | save, list |
| GET / DELETE | `/plans/{id}` | load, delete |

Identity, checked in order: our own HS256 session token (register/login), an Auth0 access token if configured, then the `X-Device-Id` header for guests. Passwords are PBKDF2-SHA256, 200k rounds, stdlib.

### MongoDB Atlas (MLH prize)

1. Free M0 cluster at cloud.mongodb.com. Database Access → add a user. Network Access → `0.0.0.0/0` for the event.
2. Connect → Drivers → paste the URI into `MONGO_URI` with the password filled in.
3. `/health` now reports `"db":"mongodb"`. Collections `users`, `profiles`, `plans` are created on first write.

### Auth0 (MLH prize)

1. Applications → Create → Native. Note Domain and Client ID. APIs → Create → the Identifier is `AUTH0_AUDIENCE`.
2. Allowed Callback and Logout URLs: `https://YOUR_TENANT.us.auth0.com/ios/onepercentchocolatemilk.rescrolly/callback`
3. Set `AUTH0_DOMAIN` and `AUTH0_AUDIENCE` in `.env`. Tokens from the Auth0 SDK are now accepted on every route.
4. iOS: add the `Auth0.swift` package, copy `Auth0.plist.example` to `Auth0.plist`, add the Associated Domains capability `webcredentials:YOUR_TENANT.us.auth0.com`. Then wire a "Continue with Auth0" button to `Auth0.webAuth().useHTTPS().start` and store `credentials.accessToken` via `APIClient.shared.token = …`. The backend accepts it as-is.

Email/password works tonight without any of this.

### Hosting: Cloudflare Tunnel from a Mac (what the app points at)

The API runs on a laptop and is published at `https://hs.poyraz.us` through a Cloudflare Tunnel. HTTPS end to end, works on any network including campus Wi-Fi, no ports opened, no App Transport Security exceptions in the app.

One-time setup (the domain is already on Cloudflare):

```bash
brew install cloudflared
cloudflared tunnel login                       # browser: pick poyraz.us
cloudflared tunnel create rescrolly
cloudflared tunnel route dns rescrolly hs.poyraz.us   # creates the CNAME
```

Every time:

```bash
cd backend && ./run.sh
```

That starts uvicorn on localhost and the tunnel in the foreground. `curl https://hs.poyraz.us/health` from anywhere should answer within a few seconds of the first run. Keep the laptop awake (System Settings → Battery → prevent sleep on power, or `caffeinate -i ./run.sh`).

### Vultr (MLH prize)

Same container, different box. Deploy Ubuntu 24.04, then:

```bash
apt update && apt install -y docker.io git
git clone <repo> && cd reScrolly/backend && cp .env.example .env && nano .env
docker build -t reScrolly . && docker run -d --restart unless-stopped -p 127.0.0.1:8000:8000 --env-file .env reScrolly
cloudflared tunnel run --url http://localhost:8000 reScrolly   # same tunnel, moved to the server
```

Moving the tunnel to Vultr changes nothing in the app.

---

## iOS

### Add the files to your Xcode project

1. Drag the *contents* of `ios/reScrolly/` (`ReScrollyApp.swift`, `Core/`, `Onboarding/`, `Auth/`, `Main/`, `Resources/`) into the project navigator onto the `reScrolly` group. Copy items if needed, target `reScrolly` ticked.
2. Delete Xcode's generated `ContentView.swift` and its `ReScrollyApp.swift`.
3. Select `Resources/FallbackPlan.json` and confirm Target Membership.
4. Target → General → Minimum Deployments → iOS 17.0.
5. Build.

### Info tab keys (target → Info → Custom iOS Target Properties)

Both usage descriptions are already set in the target's build settings; they're listed here for reference.

| Key | Value |
|---|---|
| Privacy - Calendars Full Access Usage Description | We check your calendar for lunches and dinners so we don't plan meals you'll eat out. |
| Privacy - Camera Usage Description | Take a photo of a recipe from a cookbook or a card to add it. |
| URL Types → URL Schemes | `onepercentchocolatemilk.rescrolly` (already there for Auth0; also used for `…://import?url=`) |

Photos use `PhotosPicker`, which needs no usage string.

### Run on your iPhone

Plug in, select the device. On the phone: Settings → Privacy & Security → Developer Mode → on. After the first failed launch: Settings → General → VPN & Device Management → trust your Apple ID. Personal Team signing works for this.

### ElevenLabs (if there's time)

The honest place is `RecipeView`: a speaker button that reads the current step aloud, because hands are wet. One request to the text-to-speech endpoint per step, played with `AVAudioPlayer`. Never automatic.

### Solana

No honest fit. Skip.

---

## Design

Light, warm paper background, white cards with a hairline border, one deep green accent used only for actions and selection, system font at every size. Nothing centred except empty states. No emoji, no sparkles, no gradients. Every explanation is a fact with a unit. The app never says "AI." Tokens are in `Core/Theme.swift`; every screen is built from the same dozen components.

## Layout

```
backend/app/
  main.py            routes
  solver.py          the planner
  recipes_import.py  link / text / OCR → structured, priced recipe
  auth.py        sessions, passwords, optional Auth0
  db.py          Mongo or in-memory: users, profiles, plans
  models.py      request schemas
  data/          ingredients.json, recipes.json
ios/reScrolly/
  ReScrollyApp.swift            entry + route switch
  Core/                      Theme, Models, APIClient, Keychain, AppState, CalendarManager, NotificationManager
  Onboarding/                Welcome, OnboardingFlow, OnboardingSteps, BuildingPlan
  Auth/                      Login, CreateAccount, ForgotPassword
  Main/                      MainTab, Today, Plan, FlowGraph, RotTimeline, Recipes, RecipeImport, Shop (paper list + PDF), Cook, Profile (+ settings)
  Resources/FallbackPlan.json
```

## Adding recipes

`backend/app/data/recipes.json`. Restrictive diets (gluten-free, vegan) need more recipes than the current 29 to cover a full week, or a few user recipes pinned in. Custom ingredients created by imports get default prices; edit them in the recipe's stored `custom_ingredients` if they're off.
