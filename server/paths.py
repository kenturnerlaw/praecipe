from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
PUBLIC = ROOT / "public"
FILES = DATA / "files"
MAIL_FILES = FILES / "mail"
MATTER_FILES = FILES / "matters"
DB_PATH = DATA / "praecipe.db"


def ensure_dirs() -> None:
    for path in (DATA, FILES, MAIL_FILES, MATTER_FILES, PUBLIC):
        path.mkdir(parents=True, exist_ok=True)
