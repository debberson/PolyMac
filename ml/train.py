"""Train PolyMac's deception classifier from recorded training sessions.

Reads every data/sessions/*/questions.csv that the Mac app saved, keeps answers labeled
"truth" or "lie", and compares a few small models using cross-validation that holds out whole
subjects (so a model is always judged on people it has never seen). The best one is
retrained on all the data and written to data/models/PolyMacModel.mlmodel, where the app
picks it up (press Reload in the app's Recording & Training panel).

Run it with ml/train.sh; see ml/README.md.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import shutil
import sys
import warnings
from pathlib import Path

# scikit-learn 1.5 deprecation notices (multi_class) and coremltools version chatter aren't actionable here.
warnings.filterwarnings("ignore", category=FutureWarning)
warnings.filterwarnings("ignore", message=".*scikit-learn.*")
warnings.filterwarnings("ignore", message=".*Torch.*")

import numpy as np
import pandas as pd
from sklearn.base import clone
from sklearn.ensemble import GradientBoostingClassifier, RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import balanced_accuracy_score, confusion_matrix, roc_auc_score
from sklearn.model_selection import GroupKFold, LeaveOneGroupOut, StratifiedKFold
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

REPO = Path(__file__).resolve().parent.parent
MODEL_NAME = "PolyMacModel.mlmodel"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data", type=Path, default=REPO / "data", help="data folder (default: <repo>/data)")
    parser.add_argument("--include-simulated", action="store_true", help="also train on simulator sessions (for testing the pipeline)")
    parser.add_argument("--min-per-class", type=int, default=5, help="minimum truths and lies needed to train (default 5)")
    parser.add_argument("--dry-run", action="store_true", help="evaluate only; don't write a model")
    return parser.parse_args()


def load_answers(data_dir: Path, include_simulated: bool) -> tuple[pd.DataFrame, list[str], dict]:
    frames = []
    for questions_file in sorted((data_dir / "sessions").glob("*/questions.csv")):
        meta_file = questions_file.parent / "session.json"
        meta = json.loads(meta_file.read_text()) if meta_file.exists() else {}
        frame = pd.read_csv(questions_file)
        frame["session_folder"] = questions_file.parent.name
        frame["simulated"] = bool(meta.get("simulated", False))
        frame["feature_version"] = meta.get("feature_version", 0)
        frames.append(frame)
    if not frames:
        sys.exit(f"No sessions found in {data_dir / 'sessions'}. Record some training sessions in the app first.")

    answers = pd.concat(frames, ignore_index=True)
    counts = {"sessions": len(frames), "answers": len(answers)}
    if not include_simulated:
        counts["simulated_skipped"] = int(answers["simulated"].sum())
        answers = answers[~answers["simulated"]]

    answers = answers[answers["label"].isin(["truth", "lie"])]
    counts["labeled"] = len(answers)

    # Only train on one feature definition at a time: the newest one present.
    if len(answers):
        newest = answers["feature_version"].max()
        counts["older_feature_version_skipped"] = int((answers["feature_version"] != newest).sum())
        answers = answers[answers["feature_version"] == newest]

    feature_columns = sorted(c for c in answers.columns if c.startswith("f_") and answers[c].notna().any())
    answers = answers.dropna(subset=feature_columns)
    return answers.reset_index(drop=True), feature_columns, counts


def candidate_models() -> dict:
    return {
        "logistic_regression": make_pipeline(
            # multi_class="ovr" is what coremltools expects; for a yes/no label it's identical.
            StandardScaler(), LogisticRegression(C=0.5, class_weight="balanced", max_iter=2000, multi_class="ovr")
        ),
        "random_forest": RandomForestClassifier(
            n_estimators=300, max_depth=5, min_samples_leaf=3, class_weight="balanced", random_state=0
        ),
        "gradient_boosting": GradientBoostingClassifier(
            n_estimators=150, max_depth=2, learning_rate=0.05, subsample=0.8, random_state=0
        ),
    }


def splitter(y: np.ndarray, groups: np.ndarray):
    """Hold out whole subjects when possible; otherwise fall back to (optimistic) stratified folds."""
    n_subjects = len(np.unique(groups))
    if n_subjects >= 3:
        if n_subjects <= 20:
            return LeaveOneGroupOut(), "leave-one-subject-out"
        return GroupKFold(n_splits=10), "10-fold, subjects held out"
    folds = max(2, min(5, int(np.bincount(y).min())))
    return StratifiedKFold(n_splits=folds, shuffle=True, random_state=0), f"{folds}-fold stratified (WARNING: same subjects in train and test)"


def out_of_fold_probabilities(model, X: np.ndarray, y: np.ndarray, groups: np.ndarray, cv) -> np.ndarray:
    """Pooled out-of-fold P(lie). Folds whose training data has only one class predict the base rate."""
    probabilities = np.full(len(y), np.nan)
    for train, test in cv.split(X, y, groups):
        if len(np.unique(y[train])) < 2:
            probabilities[test] = y[train].mean()
            continue
        fitted = clone(model).fit(X[train], y[train])
        probabilities[test] = fitted.predict_proba(X[test])[:, 1]
    return probabilities


def safe_auc(y: np.ndarray, score: np.ndarray) -> float | None:
    mask = ~np.isnan(score)
    if len(np.unique(y[mask])) < 2:
        return None
    return float(roc_auc_score(y[mask], score[mask]))


def top_features(model, names: list[str], count: int = 8) -> list[tuple[str, float]]:
    final = model.steps[-1][1] if hasattr(model, "steps") else model
    if hasattr(final, "coef_"):
        weights = final.coef_[0]
    elif hasattr(final, "feature_importances_"):
        weights = final.feature_importances_
    else:
        return []
    order = np.argsort(-np.abs(weights))[:count]
    return [(names[i], float(weights[i])) for i in order]


def export_coreml(model, feature_names: list[str], path: Path, info: dict) -> None:
    import coremltools as ct

    mlmodel = ct.converters.sklearn.convert(model, input_features=feature_names, output_feature_names="deceptive")
    mlmodel.author = "PolyMac ml/train.py"
    mlmodel.short_description = "P(answer was a lie) from PolyMac per-question features. Arousal, not honesty."
    mlmodel.user_defined_metadata.update({k: str(v) for k, v in info.items() if not isinstance(v, (list, dict))})
    mlmodel.save(str(path))


def main() -> None:
    args = parse_args()
    data_dir = args.data.resolve()
    answers, feature_columns, counts = load_answers(data_dir, args.include_simulated)

    print(f"Data: {data_dir}")
    print(f"  {counts['sessions']} sessions, {counts['answers']} answers")
    if counts.get("simulated_skipped"):
        print(f"  skipped {counts['simulated_skipped']} simulated answers (use --include-simulated to keep them)")
    if counts.get("older_feature_version_skipped"):
        print(f"  skipped {counts['older_feature_version_skipped']} answers recorded with an older feature version")

    y = (answers["label"] == "lie").to_numpy(dtype=int) if len(answers) else np.array([], dtype=int)
    n_lies, n_truths = int(y.sum()), int(len(y) - y.sum())
    n_subjects = answers["subject_id"].nunique() if len(answers) else 0
    print(f"  usable: {len(answers)} labeled answers ({n_lies} lies, {n_truths} truths) from {n_subjects} subjects\n")

    if min(n_lies, n_truths) < args.min_per_class:
        sys.exit(f"Not enough labeled data yet: need at least {args.min_per_class} lies and {args.min_per_class} truths. Run more training sessions.")
    if n_subjects < 10 or len(answers) < 150:
        print("NOTE: this is a small dataset. Expect noisy results until you have ~20+ subjects and a few hundred answers.\n")

    X = answers[feature_columns].to_numpy(dtype=float)
    groups = answers["subject_id"].to_numpy()
    cv, cv_name = splitter(y, groups)
    print(f"Evaluation: {cv_name}\n")

    rule_auc = None
    if "rule_index" in answers and answers["rule_index"].notna().any():
        rule_auc = safe_auc(y, answers["rule_index"].to_numpy(dtype=float))

    results = {}
    print(f"{'model':<22}{'AUC':>8}{'bal. acc':>10}")
    if rule_auc is not None:
        print(f"{'rule-based (current)':<22}{rule_auc:>8.3f}{'':>10}")
    for name, model in candidate_models().items():
        try:
            probabilities = out_of_fold_probabilities(model, X, y, groups, cv)
        except ValueError as error:
            print(f"{name:<22}  failed: {error}")
            continue
        auc = safe_auc(y, probabilities)
        balanced = float(balanced_accuracy_score(y, probabilities >= 0.5))
        results[name] = {"auc": auc, "balanced_accuracy": balanced, "probabilities": probabilities}
        print(f"{name:<22}{(auc or float('nan')):>8.3f}{balanced:>10.3f}")

    scored = {k: v for k, v in results.items() if v["auc"] is not None}
    if not scored:
        sys.exit("\nNo model could be evaluated. Collect more varied data.")
    best_name = max(scored, key=lambda k: scored[k]["auc"])
    best = scored[best_name]
    print(f"\nBest: {best_name} (AUC {best['auc']:.3f})")
    if rule_auc is not None:
        verdict = "beats" if best["auc"] > rule_auc else "does NOT beat"
        print(f"  {verdict} the rule-based score (AUC {rule_auc:.3f}) on held-out data")
    print("  AUC: 0.5 = coin flip, 1.0 = perfect. Confusion matrix at 50% (rows = truth, lie):")
    print("  " + str(confusion_matrix(y, best["probabilities"] >= 0.5)).replace("\n", "\n  "))

    final_model = clone(candidate_models()[best_name]).fit(X, y)
    feature_names = [c.removeprefix("f_") for c in feature_columns]
    print("\nMost influential features:")
    for name, weight in top_features(final_model, feature_names):
        print(f"  {name:<24}{weight:+.3f}")

    if args.dry_run:
        print("\nDry run: no model written.")
        return

    info = {
        "model_type": best_name,
        "cv_auc": round(best["auc"], 4),
        "cv_balanced_accuracy": round(best["balanced_accuracy"], 4),
        "rule_auc": round(rule_auc, 4) if rule_auc is not None else None,
        "evaluation": cv_name,
        "n_questions": int(len(answers)),
        "n_subjects": int(n_subjects),
        "n_lies": n_lies,
        "n_truths": n_truths,
        "included_simulated": bool(args.include_simulated),
        "feature_version": int(answers["feature_version"].max()),
        "features": feature_names,
        "trained_at": dt.datetime.now().isoformat(timespec="seconds"),
    }

    models_dir = data_dir / "models"
    models_dir.mkdir(parents=True, exist_ok=True)
    model_path = models_dir / MODEL_NAME
    if model_path.exists():
        archive = models_dir / "archive" / dt.datetime.now().strftime("%Y-%m-%d_%H%M%S")
        archive.mkdir(parents=True)
        shutil.move(str(model_path), archive / MODEL_NAME)
        if (models_dir / "model_info.json").exists():
            shutil.move(str(models_dir / "model_info.json"), archive / "model_info.json")
        print(f"\nPrevious model archived to {archive.relative_to(data_dir)}")

    export_coreml(final_model, feature_names, model_path, info)
    (models_dir / "model_info.json").write_text(json.dumps(info, indent=2))
    print(f"\nSaved {model_path}")
    print("In the app: Recording & Training → Reload, then turn on \"Use trained model for verdicts\".")


if __name__ == "__main__":
    main()
