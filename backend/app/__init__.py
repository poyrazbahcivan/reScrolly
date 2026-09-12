from pathlib import Path

from dotenv import load_dotenv

# Modules read their settings at import time, so the .env has to load first.
# Variables already in the environment (docker --env-file, run.sh) win.
load_dotenv(Path(__file__).resolve().parent.parent / ".env")
