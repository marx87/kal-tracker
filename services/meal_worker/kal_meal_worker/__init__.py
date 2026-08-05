"""Worker locale di Coach360: foto dei pasti, piano settimanale, coach."""

from .analyzer_errors import AnalyzerError
from .claude_analyzer import ClaudeAnalyzer, ClaudeAnalyzerError
from .coach_analyzer import ClaudeCoach, ClaudeCoachError
from .coach_contract import (
    CoachContractError,
    CoachNarrativeResult,
    CoachRequest,
    ensure_text_only,
)
from .codex_analyzer import CodexAnalyzer, CodexAnalyzerError
from .contract import AnalysisResult, ContractError, FoodSuggestion
from .plan_analyzer import ClaudePlanner, ClaudePlannerError
from .plan_contract import (
    PlanContractError,
    PlanRecipeOption,
    PlanRequest,
    WeeklyPlanResult,
)

__all__ = [
    "AnalysisResult",
    "AnalyzerError",
    "ClaudeAnalyzer",
    "ClaudeAnalyzerError",
    "ClaudeCoach",
    "ClaudeCoachError",
    "ClaudePlanner",
    "ClaudePlannerError",
    "CoachContractError",
    "CoachNarrativeResult",
    "CoachRequest",
    "CodexAnalyzer",
    "CodexAnalyzerError",
    "ContractError",
    "FoodSuggestion",
    "PlanContractError",
    "PlanRecipeOption",
    "PlanRequest",
    "WeeklyPlanResult",
    "ensure_text_only",
]
