from ..models import Word


def compute_priority(word: Word) -> float:
    """
    Priority score = (encounter_count * source_diversity_count) / familiarity_denominator

    familiarity_score mapping:
      -1 (ignored)  → 0.0 (dropped from queue)
       0 (unknown)  → use 0.5 as denominator (doubles score vs. learning)
       1 (learning) → use 1.0
       2 (known)    → use 2.0 (heavily deprioritized)
    """
    if word.familiarity_score == -1:
        return 0.0
    denominator = word.familiarity_score if word.familiarity_score > 0 else 0.5
    return (word.encounter_count * word.source_diversity_count) / denominator
