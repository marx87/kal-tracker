"""Contratto del coach: entrano numeri gia' fatti, esce soltanto il racconto.

E' la terza coda della famiglia, ma il verso del traffico e' INVERTITO
rispetto al piano settimanale. Nel piano il modello SCEGLIE (``recipeId`` e
porzioni) e l'app calcola i numeri; qui l'app ha gia' calcolato tutto — TDEE
misurato, aderenza, ricomposizione, proiezione, semaforo del sovrallenamento —
e manda quei numeri gia' fatti nella richiesta. Dal Mac torna solo il perche'.

Due regole sono incise qui, una volta sola:

* **il modello non produce numeri**. Il risultato non ha un solo campo
  numerico: ha un titolo e dei capoversi, e basta. Non e' pero' una questione
  di struttura, perche' i capoversi sono prosa: un «circa 600 kcal» scritto
  dal modello accanto ai «772 kcal» calcolati dall'app darebbe a Marco due
  numeri diversi, e quello sbagliato sarebbe il primo. Per questo il testo con
  cifre SPARISCE (vedi ``_free_text``), esattamente come nel piano;
* **si scarta il capoverso, non il rapporto**. Un commento buono non si butta
  per una frase; una frase con dentro un numero inventato non si mostra
  nemmeno. Solo se non resta niente il job fallisce.

La differenza vera con il piano e' che qui la regola non e' un'intenzione del
codice: la impone il database. ``kal_tracker.coach_result_is_text_only``
rifiuta qualunque campo del risultato che non sia una stringa o un array di
stringhe, e la CHECK sulla colonna ``result`` la applica prima che il commento
arrivi al telefono. ``ensure_text_only`` qui sotto e' il gemello Python di
quella funzione: serve a far fallire il worker con un messaggio leggibile
invece che con una CHECK violation di Postgres.

La validazione e' pura: nessuna rete, nessun file, nessun processo figlio.
"""

from __future__ import annotations

import json
import re
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import date
from typing import Any


class CoachContractError(ValueError):
    """Richiesta o commento fuori contratto.

    ``error_code`` e' stabile e arriva fino a ``fail_coach_job``: e' l'unica
    cosa che l'app vede quando un commento viene rifiutato, quindi non deve
    mai contenere testo prodotto dal modello.
    """

    def __init__(self, message: str, *, error_code: str) -> None:
        self.error_code = error_code
        super().__init__(message)


SCHEMA_VERSION = 1

# Gli stessi limiti di `CoachNarrative` lato Dart: oltre cinque capoversi non
# e' un commento, e' un tema. Superarli qui vorrebbe dire far scartare il
# testo all'app dopo averlo fatto scrivere al modello.
MAXIMUM_PARAGRAPHS = 5
MAXIMUM_PARAGRAPH = 400
MAXIMUM_HEADLINE = 120

# `octet_length(result::text) <= 65536` nella CHECK della colonna. Il nostro
# risultato piu' grande possibile sta in ~2 KB: il controllo esiste perche' il
# limite del database sia dichiarato anche qui, non perche' ci si arrivi.
MAXIMUM_RESULT_BYTES = 65536

MAXIMUM_HEADLINES = 12
MAXIMUM_HEADLINE_LINE = 300
MAXIMUM_ADHERENCE_LINES = 8
MAXIMUM_SIGNALS = 12

# Codici errore stabili.
BAD_REQUEST = "COACH_BAD_REQUEST"
BAD_RESULT = "COACH_BAD_RESULT"
EMPTY_NARRATIVE = "COACH_EMPTY_NARRATIVE"
RESULT_NOT_TEXT = "COACH_RESULT_NOT_TEXT"
RESULT_TOO_LARGE = "COACH_RESULT_TOO_LARGE"

_DATE_PATTERN = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")

# I nomi degli enum Dart (`onTrack`, `risingEffort`, `falseDrop`, ...) viaggiano
# come identificatori: qui si verifica che siano tali, non che appartengano a
# una lista chiusa. Il motivo e' che nel coach queste parole finiscono solo nel
# prompt e non guidano nessun calcolo: un grado nuovo aggiunto nell'app non
# deve trasformare un rapporto intero in un job fallito.
_IDENTIFIER = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,39}$")

# L'unica eccezione: da questa parola dipende cosa il modello puo' affermare
# sul consumo (misurato sui dati veri oppure ancora stimato). Lista chiusa.
TDEE_SOURCES = ("misurato", "stimato")

_MAXIMUM_LABEL = 60
_MAXIMUM_UNIT = 16


def _fail(message: str, error_code: str) -> CoachContractError:
    return CoachContractError(message, error_code=error_code)


def _mapping(value: Any, field: str, error_code: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise _fail(f"{field} deve essere un oggetto JSON", error_code)
    return value


def _sequence(value: Any, field: str, error_code: str) -> list[Any]:
    if not isinstance(value, list):
        raise _fail(f"{field} deve essere una lista", error_code)
    return value


def _text(value: Any, field: str, *, maximum: int, error_code: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise _fail(f"{field} deve essere una stringa non vuota", error_code)
    normalized = value.strip()
    if len(normalized) > maximum:
        raise _fail(f"{field} supera {maximum} caratteri", error_code)
    return normalized


def _optional_text(
    value: Any, field: str, *, maximum: int, error_code: str
) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise _fail(f"{field} deve essere una stringa", error_code)
    normalized = value.strip()
    if not normalized:
        return None
    if len(normalized) > maximum:
        raise _fail(f"{field} supera {maximum} caratteri", error_code)
    return normalized


def _identifier(value: Any, field: str, *, error_code: str) -> str:
    name = _text(value, field, maximum=40, error_code=error_code)
    if _IDENTIFIER.fullmatch(name) is None:
        raise _fail(f"{field} non e un nome ammesso", error_code)
    return name


def _number(value: Any, field: str, error_code: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise _fail(f"{field} deve essere numerico", error_code)
    result = float(value)
    if result != result or result in (float("inf"), float("-inf")):
        raise _fail(f"{field} deve essere finito", error_code)
    # Un intero resta intero. Non e' pignoleria: questi valori finiscono nel
    # prompt, e «2680» e «2680.0» sono lo stesso consumo ma il secondo sembra
    # una precisione che non c'e'. L'app arrotonda gia' cio' che va arrotondato.
    return value if isinstance(value, int) else result


def _optional_number(value: Any, field: str, error_code: str) -> float | None:
    """Un numero che puo' mancare davvero.

    Nel rapporto un `null` non e' un buco da riempire: e' «questa settimana
    non lo so», e il commento deve poterlo dire invece di inventarlo.
    """
    if value is None:
        return None
    return _number(value, field, error_code)


def _whole(value: Any, field: str, *, maximum: int, error_code: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise _fail(f"{field} deve essere un intero", error_code)
    if not 0 <= value <= maximum:
        raise _fail(f"{field} deve stare fra 0 e {maximum}", error_code)
    return value


def _optional_signed_whole(
    value: Any, field: str, *, maximum: int, error_code: str
) -> int | None:
    """Intero con segno che puo' anche non esserci.

    Le settimane di ritardo possono essere in anticipo (negative), quindi
    l'intervallo e' simmetrico. Fuori scala il valore si tratta come ASSENTE,
    non come errore: nasce da una sottrazione fra la data promessa e quella
    proiettata, e una data obiettivo digitata con l'anno sbagliato darebbe
    mille settimane. Rifiutare la richiesta vorrebbe dire spegnere il commento
    di ogni settimana successiva (`COACH_BAD_REQUEST` non e' ritentabile) per
    un dettaglio di contorno: le due date restano nel rapporto e il modello
    puo' leggerle da se'.

    Resta un errore il tipo sbagliato: quello non e' un dato strano, e' una
    richiesta che non viene dall'app che conosciamo.
    """
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise _fail(f"{field} deve essere un intero", error_code)
    if not -maximum <= value <= maximum:
        return None
    return value


def _flag(value: Any, field: str, error_code: str) -> bool:
    if not isinstance(value, bool):
        raise _fail(f"{field} deve essere vero o falso", error_code)
    return value


def parse_coach_date(value: Any, field: str, *, error_code: str) -> date:
    """Data di calendario ISO stretta: ``AAAA-MM-GG`` e nient'altro.

    ``date.fromisoformat`` accetterebbe anche forme compatte e con orario:
    qui la data e' un'etichetta di giorno, quindi una sola forma e' ammessa.
    """
    if not isinstance(value, str):
        raise _fail(f"{field} deve essere una data ISO", error_code)
    match = _DATE_PATTERN.fullmatch(value.strip())
    if match is None:
        raise _fail(f"{field} non e una data AAAA-MM-GG", error_code)
    try:
        return date(int(match[1]), int(match[2]), int(match[3]))
    except ValueError as error:
        raise _fail(f"{field} non e una data esistente", error_code) from error


def _optional_coach_date(value: Any, field: str, *, error_code: str) -> date | None:
    if value is None:
        return None
    return parse_coach_date(value, field, error_code=error_code)


def format_coach_date(value: date) -> str:
    return value.isoformat()


def _is_numeric_text(text: str) -> bool:
    """Vero se nel testo compare un carattere che vale come numero.

    Non basta `\\d` (categoria Unicode Nd): «hai perso ½ chilo piu' del
    previsto» passerebbe indenne, e sarebbe di nuovo un numero del modello
    accanto ai numeri veri dell'app. `str.isnumeric` copre in un colpo solo le
    cifre decimali (Nd), le altre forme numeriche (No: ½, ¾, ①) e i numerali
    (Nl: Ⅶ), senza liste da mantenere.

    Resta fuori solo il numero scritto in lettere («settecento kcal»): li' non
    esiste un test che non cancelli anche «un chilo» e «una settimana», quindi
    quel pezzo di regola lo porta il prompt.
    """
    return any(character.isnumeric() for character in text)


def _free_text(value: Any, *, maximum: int) -> str | None:
    """Testo del modello: ammesso, ma senza cifre.

    E' l'altra meta' della regola «i numeri li calcola l'app»: lo schema non ha
    campi numerici, ma titolo e capoversi sono prosa e una cifra li
    trasformerebbe in una dichiarazione accanto al numero vero.

    Non solleva mai: un testo sporco vale come testo assente, ed e' il
    chiamante a decidere se cio' che resta basta. Cosi' un commento buono non
    si butta per una frase.
    """
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text or len(text) > maximum:
        return None
    if _is_numeric_text(text):
        return None
    return text


def ensure_text_only(payload: Mapping[str, Any]) -> None:
    """Gemello Python di ``kal_tracker.coach_result_is_text_only``.

    Il database rifiuta il risultato che non lo soddisfa, ma lo rifiuta come
    violazione di CHECK: un errore che dice «il vincolo X e' violato», non
    «hai messo un numero nel campo Y». Verificarlo qui serve solo a questo —
    che l'errore sia leggibile e che il worker sappia cosa ha sbagliato.

    Anche la semantica dei casi vuoti e' copiata: in SQL ``bool_and`` su un
    insieme vuoto torna NULL e ``is not false`` lo fa passare, quindi un
    oggetto senza campi e un array vuoto di stringhe sono validi. Qui lo fa
    ``all()``, che su una sequenza vuota e' vero.
    """
    for key, value in payload.items():
        if isinstance(value, str):
            continue
        if isinstance(value, list) and all(
            isinstance(item, str) for item in value
        ):
            continue
        raise _fail(
            f"Il campo {key!r} del commento non e testo: i numeri li calcola "
            "l'app",
            RESULT_NOT_TEXT,
        )


@dataclass(frozen=True)
class CoachTdeeFacts:
    """Il consumo della settimana, gia' misurato o gia' stimato dall'app."""

    kcal: float
    source: str
    average_daily_kcal: float | None
    weight_change_kg: float | None
    diary_days: int
    weigh_in_days: int

    @property
    def is_measured(self) -> bool:
        return self.source == TDEE_SOURCES[0]

    @classmethod
    def from_json(cls, value: Any) -> "CoachTdeeFacts":
        payload = _mapping(value, "tdee", BAD_REQUEST)
        source = _text(
            payload.get("source"), "tdee.source", maximum=20, error_code=BAD_REQUEST
        ).lower()
        if source not in TDEE_SOURCES:
            raise _fail(
                f"Origine del consumo non riconosciuta: {source!r}", BAD_REQUEST
            )
        return cls(
            kcal=_number(payload.get("kcal"), "tdee.kcal", BAD_REQUEST),
            source=source,
            average_daily_kcal=_optional_number(
                payload.get("average_daily_kcal"),
                "tdee.average_daily_kcal",
                BAD_REQUEST,
            ),
            weight_change_kg=_optional_number(
                payload.get("weight_change_kg"), "tdee.weight_change_kg", BAD_REQUEST
            ),
            diary_days=_whole(
                payload.get("diary_days", 0),
                "tdee.diary_days",
                maximum=31,
                error_code=BAD_REQUEST,
            ),
            weigh_in_days=_whole(
                payload.get("weigh_in_days", 0),
                "tdee.weigh_in_days",
                maximum=31,
                error_code=BAD_REQUEST,
            ),
        )

    def to_json(self) -> dict[str, Any]:
        return {
            "kcal": self.kcal,
            "source": self.source,
            "average_daily_kcal": self.average_daily_kcal,
            "weight_change_kg": self.weight_change_kg,
            "diary_days": self.diary_days,
            "weigh_in_days": self.weigh_in_days,
        }


@dataclass(frozen=True)
class CoachAdherenceLine:
    """Una riga di aderenza: previsto, reale e quanti giorni mancano."""

    label: str
    grade: str
    planned: float | None
    actual: float | None
    unit: str | None
    days_counted: int
    days_missing: int

    @classmethod
    def from_json(cls, value: Any, *, index: int) -> "CoachAdherenceLine":
        field = f"adherence.lines[{index}]"
        payload = _mapping(value, field, BAD_REQUEST)
        return cls(
            label=_text(
                payload.get("label"),
                f"{field}.label",
                maximum=_MAXIMUM_LABEL,
                error_code=BAD_REQUEST,
            ),
            grade=_identifier(
                payload.get("grade"), f"{field}.grade", error_code=BAD_REQUEST
            ),
            planned=_optional_number(
                payload.get("planned"), f"{field}.planned", BAD_REQUEST
            ),
            actual=_optional_number(
                payload.get("actual"), f"{field}.actual", BAD_REQUEST
            ),
            unit=_optional_text(
                payload.get("unit"),
                f"{field}.unit",
                maximum=_MAXIMUM_UNIT,
                error_code=BAD_REQUEST,
            ),
            days_counted=_whole(
                payload.get("days_counted", 0),
                f"{field}.days_counted",
                maximum=31,
                error_code=BAD_REQUEST,
            ),
            days_missing=_whole(
                payload.get("days_missing", 0),
                f"{field}.days_missing",
                maximum=31,
                error_code=BAD_REQUEST,
            ),
        )

    def to_json(self) -> dict[str, Any]:
        return {
            "label": self.label,
            "grade": self.grade,
            "planned": self.planned,
            "actual": self.actual,
            "unit": self.unit,
            "days_counted": self.days_counted,
            "days_missing": self.days_missing,
        }


@dataclass(frozen=True)
class CoachAdherenceFacts:
    overall: str
    lines: tuple[CoachAdherenceLine, ...]

    @classmethod
    def from_json(cls, value: Any) -> "CoachAdherenceFacts":
        payload = _mapping(value, "adherence", BAD_REQUEST)
        entries = _sequence(payload.get("lines", []), "adherence.lines", BAD_REQUEST)
        if len(entries) > MAXIMUM_ADHERENCE_LINES:
            raise _fail("Troppe righe di aderenza nella richiesta", BAD_REQUEST)
        return cls(
            overall=_identifier(
                payload.get("overall"), "adherence.overall", error_code=BAD_REQUEST
            ),
            lines=tuple(
                CoachAdherenceLine.from_json(entry, index=index)
                for index, entry in enumerate(entries)
            ),
        )

    def to_json(self) -> dict[str, Any]:
        return {
            "overall": self.overall,
            "lines": [line.to_json() for line in self.lines],
        }


@dataclass(frozen=True)
class CoachRecompositionFacts:
    """Cosa sta facendo la massa magra: e' la domanda del deficit."""

    lean_trend: str
    lean_change_kg: float | None
    fat_change_kg: float | None
    is_recomposition: bool

    @classmethod
    def from_json(cls, value: Any) -> "CoachRecompositionFacts":
        payload = _mapping(value, "recomposition", BAD_REQUEST)
        return cls(
            lean_trend=_identifier(
                payload.get("lean_trend"),
                "recomposition.lean_trend",
                error_code=BAD_REQUEST,
            ),
            lean_change_kg=_optional_number(
                payload.get("lean_change_kg"),
                "recomposition.lean_change_kg",
                BAD_REQUEST,
            ),
            fat_change_kg=_optional_number(
                payload.get("fat_change_kg"),
                "recomposition.fat_change_kg",
                BAD_REQUEST,
            ),
            is_recomposition=_flag(
                payload.get("is_recomposition", False),
                "recomposition.is_recomposition",
                BAD_REQUEST,
            ),
        )

    def to_json(self) -> dict[str, Any]:
        return {
            "lean_trend": self.lean_trend,
            "lean_change_kg": self.lean_change_kg,
            "fat_change_kg": self.fat_change_kg,
            "is_recomposition": self.is_recomposition,
        }


@dataclass(frozen=True)
class CoachProjectionFacts:
    """La proiezione del traguardo. Assente quando non c'e' un obiettivo."""

    state: str
    target_weight_kg: float | None
    current_average_kg: float | None
    observed_kg_per_week: float | None
    projected_date: date | None
    planned_date: date | None
    weeks_late: int | None

    @classmethod
    def from_json(cls, value: Any) -> "CoachProjectionFacts":
        payload = _mapping(value, "projection", BAD_REQUEST)
        return cls(
            state=_identifier(
                payload.get("state"), "projection.state", error_code=BAD_REQUEST
            ),
            target_weight_kg=_optional_number(
                payload.get("target_weight_kg"),
                "projection.target_weight_kg",
                BAD_REQUEST,
            ),
            current_average_kg=_optional_number(
                payload.get("current_average_kg"),
                "projection.current_average_kg",
                BAD_REQUEST,
            ),
            observed_kg_per_week=_optional_number(
                payload.get("observed_kg_per_week"),
                "projection.observed_kg_per_week",
                BAD_REQUEST,
            ),
            projected_date=_optional_coach_date(
                payload.get("projected_date"),
                "projection.projected_date",
                error_code=BAD_REQUEST,
            ),
            planned_date=_optional_coach_date(
                payload.get("planned_date"),
                "projection.planned_date",
                error_code=BAD_REQUEST,
            ),
            # Puo' essere negativo: essere in anticipo e' l'altra meta' della
            # stessa misura. Fuori da dieci anni in un verso o nell'altro non
            # e' piu' una misura ma una data digitata male, e allora vale come
            # assente: il rapporto vive lo stesso.
            weeks_late=_optional_signed_whole(
                payload.get("weeks_late"),
                "projection.weeks_late",
                maximum=520,
                error_code=BAD_REQUEST,
            ),
        )

    def to_json(self) -> dict[str, Any]:
        return {
            "state": self.state,
            "target_weight_kg": self.target_weight_kg,
            "current_average_kg": self.current_average_kg,
            "observed_kg_per_week": self.observed_kg_per_week,
            "projected_date": (
                None
                if self.projected_date is None
                else format_coach_date(self.projected_date)
            ),
            "planned_date": (
                None
                if self.planned_date is None
                else format_coach_date(self.planned_date)
            ),
            "weeks_late": self.weeks_late,
        }


@dataclass(frozen=True)
class CoachOvertrainingFacts:
    """Il semaforo del sovrallenamento, con i segnali accesi e quelli muti.

    ``unknown`` non e' ``quiet``: un segnale che non si sa non e' un segnale
    tranquillo, e il commento non deve trattarlo come tale.
    """

    level: str
    fired: tuple[str, ...]
    unknown: tuple[str, ...]

    @classmethod
    def from_json(cls, value: Any) -> "CoachOvertrainingFacts":
        payload = _mapping(value, "overtraining", BAD_REQUEST)
        return cls(
            level=_identifier(
                payload.get("level"), "overtraining.level", error_code=BAD_REQUEST
            ),
            fired=_signal_names(payload.get("fired", []), "overtraining.fired"),
            unknown=_signal_names(payload.get("unknown", []), "overtraining.unknown"),
        )

    def to_json(self) -> dict[str, Any]:
        return {
            "level": self.level,
            "fired": list(self.fired),
            "unknown": list(self.unknown),
        }


def _signal_names(value: Any, field: str) -> tuple[str, ...]:
    entries = _sequence(value, field, BAD_REQUEST)
    if len(entries) > MAXIMUM_SIGNALS:
        raise _fail(f"{field} contiene troppi segnali", BAD_REQUEST)
    return tuple(
        _identifier(entry, f"{field}[{index}]", error_code=BAD_REQUEST)
        for index, entry in enumerate(entries)
    )


@dataclass(frozen=True)
class CoachFalseMovementFacts:
    """Il peso che si muove per idratazione e non per grasso."""

    kind: str
    daily_change_kg: float | None
    trend_change_kg: float | None

    @classmethod
    def from_json(cls, value: Any) -> "CoachFalseMovementFacts":
        payload = _mapping(value, "false_movement", BAD_REQUEST)
        return cls(
            kind=_identifier(
                payload.get("kind"), "false_movement.kind", error_code=BAD_REQUEST
            ),
            daily_change_kg=_optional_number(
                payload.get("daily_change_kg"),
                "false_movement.daily_change_kg",
                BAD_REQUEST,
            ),
            trend_change_kg=_optional_number(
                payload.get("trend_change_kg"),
                "false_movement.trend_change_kg",
                BAD_REQUEST,
            ),
        )

    def to_json(self) -> dict[str, Any]:
        return {
            "kind": self.kind,
            "daily_change_kg": self.daily_change_kg,
            "trend_change_kg": self.trend_change_kg,
        }


@dataclass(frozen=True)
class CoachDataQuality:
    """Quante caselle del rapporto sono piene: un voto sui DATI, non sulla
    settimana. Serve al commento per non far sembrare solida una lettura fatta
    su due pesate."""

    filled: int
    total: int

    @classmethod
    def from_json(cls, value: Any) -> "CoachDataQuality":
        payload = _mapping(value, "data_quality", BAD_REQUEST)
        total = _whole(
            payload.get("total", 0),
            "data_quality.total",
            maximum=32,
            error_code=BAD_REQUEST,
        )
        filled = _whole(
            payload.get("filled", 0),
            "data_quality.filled",
            maximum=32,
            error_code=BAD_REQUEST,
        )
        if filled > total:
            raise _fail("data_quality.filled supera data_quality.total", BAD_REQUEST)
        return cls(filled=filled, total=total)

    def to_json(self) -> dict[str, Any]:
        return {"filled": self.filled, "total": self.total}


@dataclass(frozen=True)
class CoachRequest:
    """La richiesta che l'app ha messo nel job: il rapporto gia' calcolato.

    Niente qui dentro e' materia da ricalcolare. E' il testo del compito: il
    modello lo legge e scrive il perche'.
    """

    week_start: date
    week_end: date
    tdee: CoachTdeeFacts
    adherence: CoachAdherenceFacts
    recomposition: CoachRecompositionFacts
    overtraining: CoachOvertrainingFacts
    false_movement: CoachFalseMovementFacts
    workouts_done: int
    data_quality: CoachDataQuality
    headlines: tuple[str, ...]
    projection: CoachProjectionFacts | None = None

    @classmethod
    def from_json(cls, value: Any) -> "CoachRequest":
        payload = _mapping(value, "request", BAD_REQUEST)

        # L'app non scrive `schema` nella richiesta del coach: si accetta se
        # c'e' (per una versione futura) e si rifiuta solo se dichiara una
        # forma che questo worker non sa leggere.
        schema = payload.get("schema")
        if schema is not None and schema != SCHEMA_VERSION:
            raise _fail(
                f"Schema della richiesta non supportato: {schema!r}", BAD_REQUEST
            )

        week_start = parse_coach_date(
            payload.get("week_start"), "week_start", error_code=BAD_REQUEST
        )
        week_end = parse_coach_date(
            payload.get("week_end"), "week_end", error_code=BAD_REQUEST
        )
        if week_end < week_start:
            raise _fail("La settimana finisce prima di iniziare", BAD_REQUEST)
        if (week_end - week_start).days > 31:
            raise _fail("La settimana del rapporto e troppo lunga", BAD_REQUEST)

        raw_headlines = _sequence(
            payload.get("headlines", []), "headlines", BAD_REQUEST
        )
        if len(raw_headlines) > MAXIMUM_HEADLINES:
            raise _fail("Troppe frasi gia' scritte nella richiesta", BAD_REQUEST)
        # Le headline SONO piene di cifre, ed e' giusto cosi': sono i numeri
        # dell'app. Il divieto di cifre vale sul testo del modello, non su
        # quello che il modello legge.
        headlines = tuple(
            _text(
                entry,
                f"headlines[{index}]",
                maximum=MAXIMUM_HEADLINE_LINE,
                error_code=BAD_REQUEST,
            )
            for index, entry in enumerate(raw_headlines)
        )

        raw_projection = payload.get("projection")

        return cls(
            week_start=week_start,
            week_end=week_end,
            tdee=CoachTdeeFacts.from_json(payload.get("tdee")),
            adherence=CoachAdherenceFacts.from_json(payload.get("adherence")),
            recomposition=CoachRecompositionFacts.from_json(
                payload.get("recomposition")
            ),
            overtraining=CoachOvertrainingFacts.from_json(payload.get("overtraining")),
            false_movement=CoachFalseMovementFacts.from_json(
                payload.get("false_movement")
            ),
            workouts_done=_whole(
                payload.get("workouts_done", 0),
                "workouts_done",
                maximum=100,
                error_code=BAD_REQUEST,
            ),
            data_quality=CoachDataQuality.from_json(payload.get("data_quality")),
            headlines=headlines,
            # Senza obiettivo non c'e' proiezione, e un rapporto senza
            # proiezione resta un rapporto.
            projection=(
                None
                if raw_projection is None
                else CoachProjectionFacts.from_json(raw_projection)
            ),
        )

    @property
    def themes(self) -> int:
        """Quanti argomenti il commento deve trattare.

        Una headline e' un tema: e' la misura di quanto c'e' da spiegare, ed e'
        con questa che si dimensiona il tempo concesso al modello.
        """
        return max(1, len(self.headlines))

    def to_json(self) -> dict[str, Any]:
        """Forma canonica della richiesta: e' quella che va nel prompt.

        Ricostruita campo per campo, cosi' una chiave in piu' scritta da una
        versione futura dell'app non raggiunge mai il modello.
        """
        return {
            "schema": SCHEMA_VERSION,
            "week_start": format_coach_date(self.week_start),
            "week_end": format_coach_date(self.week_end),
            "tdee": self.tdee.to_json(),
            "adherence": self.adherence.to_json(),
            "recomposition": self.recomposition.to_json(),
            "projection": (
                None if self.projection is None else self.projection.to_json()
            ),
            "overtraining": self.overtraining.to_json(),
            "false_movement": self.false_movement.to_json(),
            "workouts_done": self.workouts_done,
            "data_quality": self.data_quality.to_json(),
            "headlines": list(self.headlines),
        }


@dataclass(frozen=True)
class CoachNarrativeResult:
    """Il commento validato: un titolo facoltativo e dei capoversi. Solo testo.

    ``dropped`` conta cosa e' stato buttato via (cifre, vuoti, troppo lungo,
    capoversi oltre il quinto). **Non torna al database**: sarebbe un numero, e
    un numero nel risultato lo rifiuta la CHECK. Serve al log del worker, dove
    un modello che continua a scrivere cifre si deve vedere.
    """

    paragraphs: tuple[str, ...]
    headline: str | None = None
    dropped: int = 0

    @classmethod
    def from_json(cls, value: Any) -> "CoachNarrativeResult":
        payload = _mapping(value, "Il commento", BAD_RESULT)

        schema = payload.get("schema")
        if schema is not None and schema != SCHEMA_VERSION:
            raise _fail(f"Schema del commento non supportato: {schema!r}", BAD_RESULT)

        entries = _sequence(payload.get("paragraphs"), "paragraphs", BAD_RESULT)

        kept: list[str] = []
        dropped = 0
        for entry in entries:
            if len(kept) >= MAXIMUM_PARAGRAPHS:
                dropped += 1
                continue
            text = _free_text(entry, maximum=MAXIMUM_PARAGRAPH)
            if text is None:
                dropped += 1
                continue
            kept.append(text)

        if not kept:
            # Tutto scartato: qui non resta un commento a meta', resta il
            # silenzio. Meglio dichiararlo che mandare all'app un oggetto
            # vuoto che lei scarterebbe di nuovo.
            raise _fail(
                "Il commento non contiene un solo capoverso utilizzabile",
                EMPTY_NARRATIVE,
            )

        return cls(
            paragraphs=tuple(kept),
            headline=_free_text(payload.get("headline"), maximum=MAXIMUM_HEADLINE),
            dropped=dropped,
        )

    def to_json(self) -> dict[str, Any]:
        """Il payload esatto di ``complete_coach_job``, gia' verificato.

        Il titolo si OMETTE quando non c'e': un ``null`` non e' una stringa e
        ``coach_result_is_text_only`` lo rifiuterebbe. E' l'errore piu' facile
        da fare qui dentro, quindi la verifica sta dentro il costruttore del
        payload e non in un passo che si puo' dimenticare di chiamare.
        """
        payload: dict[str, Any] = {"paragraphs": list(self.paragraphs)}
        if self.headline is not None:
            payload["headline"] = self.headline

        ensure_text_only(payload)
        encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
        if len(encoded.encode("utf-8")) > MAXIMUM_RESULT_BYTES:
            raise _fail("Il commento supera la dimensione ammessa", RESULT_TOO_LARGE)
        return payload
