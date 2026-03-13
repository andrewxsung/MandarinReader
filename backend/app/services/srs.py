from datetime import date, datetime, timedelta, timezone
from ..models import Word

MIN_EASE_FACTOR = 1.3
MAX_EASE_FACTOR = 4.0


def apply_review(word: Word, result: str) -> None:
    """
    Apply SM-2 spaced repetition update to word in-place.
    result must be one of: 'known', 'learning', 'ignore'
    """
    if result == "ignore":
        word.familiarity_score = -1
        word.next_review_date = None
        word.last_reviewed = datetime.now(timezone.utc)
        return

    if result == "known":
        word.familiarity_score = 2
        word.ease_factor = min(float(word.ease_factor) + 0.1, MAX_EASE_FACTOR)
        new_interval = round(word.srs_interval_days * float(word.ease_factor))
        word.srs_interval_days = max(new_interval, 2)
        word.next_review_date = date.today() + timedelta(days=word.srs_interval_days)
        word.last_reviewed = datetime.now(timezone.utc)
        return

    # result == "learning"
    word.familiarity_score = 1
    word.ease_factor = max(float(word.ease_factor) - 0.2, MIN_EASE_FACTOR)
    word.srs_interval_days = 1
    word.next_review_date = date.today()  # immediately reviewable (not tomorrow)
    word.last_reviewed = datetime.now(timezone.utc)
