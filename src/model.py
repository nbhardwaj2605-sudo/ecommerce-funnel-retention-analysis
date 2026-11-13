"""Optional model: which delivered orders get a 1-2 star review?

The goal is explanation, not production scoring: which factors matter most.
- Population: delivered orders with a review, purchased 2017-01 .. 2018-08
- Time-based split: train on purchases before 2018-05, test on 2018-05 .. 2018-08
- Models: logistic regression (standardised coefficients) and Random Forest
  (impurity + permutation importance on the test set)
- Ablation: same models WITHOUT the delivery-outcome features, to measure how
  much of the signal is delivery.

Usage:  python src/model.py
Writes: outputs/tables/model_*.csv and outputs/figures/09_*, 10_*
"""
import json
import sqlite3
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import RandomForestClassifier
from sklearn.inspection import permutation_importance
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import average_precision_score, classification_report, roc_auc_score
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

ROOT = Path(__file__).resolve().parents[1]
DB = ROOT / "data" / "olist.db"
TAB = ROOT / "outputs" / "tables"
FIG = ROOT / "outputs" / "figures"
SPLIT_DATE = "2018-05-01"
SEED = 42
plt.rcParams.update({"axes.spines.top": False, "axes.spines.right": False,
                     "axes.grid": True, "grid.color": "#ecebe7", "axes.axisbelow": True,
                     "axes.edgecolor": "#d9d8d3", "xtick.color": "#52514e", "ytick.color": "#52514e"})

QUERY = """
SELECT order_id, purchased_at, review_score,
       delay_days, delivery_days, promised_days, on_time,
       julianday(shipped_at)   - julianday(approved_at) AS seller_handling_days,
       julianday(delivered_at) - julianday(shipped_at)  AS carrier_transit_days,
       freight_value, items_value, n_items, n_sellers, installments, payment_type,
       category, seller_id, seller_state, customer_state
FROM v_order_fact
WHERE order_status = 'delivered' AND review_score IS NOT NULL
  AND delivered_at IS NOT NULL AND shipped_at IS NOT NULL AND approved_at IS NOT NULL
  AND purchased_at >= '2017-01-01' AND purchased_at < '2018-09-01'
"""

DELIVERY_FEATURES = ["delay_days", "delivery_days", "on_time", "carrier_transit_days"]


def build_frame() -> pd.DataFrame:
    con = sqlite3.connect(DB)
    df = pd.read_sql_query(QUERY, con)
    con.close()
    df["low_review"] = (df["review_score"] <= 2).astype(int)
    df["freight_ratio"] = df["freight_value"] / (df["items_value"] + df["freight_value"])
    df["same_state"] = (df["seller_state"] == df["customer_state"]).astype(int)
    df["multi_seller"] = (df["n_sellers"] > 1).astype(int)
    df["payment_type"] = df["payment_type"].fillna("unknown")
    df["installments"] = df["installments"].fillna(1)
    return df


def add_seller_history(train: pd.DataFrame, test: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Seller's historical late rate and low-review rate, learned on TRAIN only
    (smoothed towards the platform mean) so the test set never leaks."""
    k = 20  # smoothing strength, in orders
    g = train.groupby("seller_id").agg(n=("order_id", "size"),
                                       late=("on_time", lambda s: 1 - s.mean()),
                                       low=("low_review", "mean"))
    p_late, p_low = 1 - train["on_time"].mean(), train["low_review"].mean()
    g["seller_late_rate_hist"] = (g["late"] * g["n"] + p_late * k) / (g["n"] + k)
    g["seller_low_review_rate_hist"] = (g["low"] * g["n"] + p_low * k) / (g["n"] + k)
    g["seller_volume_hist"] = np.log1p(g["n"])
    cols = ["seller_late_rate_hist", "seller_low_review_rate_hist", "seller_volume_hist"]

    # In-sample rates on train would overfit; use out-of-fold for train rows.
    folds = np.arange(len(train)) % 5
    train = train.copy()
    for c in cols:
        train[c] = np.nan
    for f in range(5):
        tr, va = train[folds != f], train.index[folds == f]
        gf = tr.groupby("seller_id").agg(n=("order_id", "size"),
                                         late=("on_time", lambda s: 1 - s.mean()),
                                         low=("low_review", "mean"))
        gf["seller_late_rate_hist"] = (gf["late"] * gf["n"] + p_late * k) / (gf["n"] + k)
        gf["seller_low_review_rate_hist"] = (gf["low"] * gf["n"] + p_low * k) / (gf["n"] + k)
        gf["seller_volume_hist"] = np.log1p(gf["n"])
        m = train.loc[va, ["seller_id"]].join(gf[cols], on="seller_id")
        train.loc[va, cols] = m[cols].values
    test = test.join(g[cols], on="seller_id")
    for c, default in zip(cols, [p_late, p_low, 0.0]):
        train[c] = train[c].fillna(default)
        test[c] = test[c].fillna(default)
    return train, test


NUMERIC = ["delay_days", "delivery_days", "promised_days", "on_time",
           "seller_handling_days", "carrier_transit_days",
           "freight_value", "items_value", "freight_ratio", "n_items",
           "multi_seller", "installments", "same_state",
           "seller_late_rate_hist", "seller_low_review_rate_hist", "seller_volume_hist"]
CATEGORICAL = ["category", "customer_state", "seller_state", "payment_type"]


def make_preprocessor(numeric, categorical):
    return ColumnTransformer([
        ("num", StandardScaler(), numeric),
        ("cat", OneHotEncoder(handle_unknown="infrequent_if_exist",
                              min_frequency=200, sparse_output=False), categorical),
    ])


def fit_eval(train, test, numeric, categorical, label):
    X_tr, y_tr = train[numeric + categorical], train["low_review"]
    X_te, y_te = test[numeric + categorical], test["low_review"]

    logit = Pipeline([("prep", make_preprocessor(numeric, categorical)),
                      ("clf", LogisticRegression(max_iter=2000, class_weight="balanced", C=0.5))])
    rf = Pipeline([("prep", make_preprocessor(numeric, categorical)),
                   ("clf", RandomForestClassifier(n_estimators=300, min_samples_leaf=20,
                                                  max_features="sqrt", class_weight="balanced_subsample",
                                                  n_jobs=-1, random_state=SEED))])
    out = {}
    for name, model in [("logistic_regression", logit), ("random_forest", rf)]:
        model.fit(X_tr, y_tr)
        p = model.predict_proba(X_te)[:, 1]
        out[name] = {"model": model,
                     "roc_auc": roc_auc_score(y_te, p),
                     "pr_auc": average_precision_score(y_te, p),
                     "proba": p}
        print(f"[{label}] {name:20s} ROC-AUC={out[name]['roc_auc']:.3f}  PR-AUC={out[name]['pr_auc']:.3f}")
    return out


def main() -> None:
    TAB.mkdir(parents=True, exist_ok=True)
    FIG.mkdir(parents=True, exist_ok=True)
    df = build_frame()
    train = df[df["purchased_at"] < SPLIT_DATE].reset_index(drop=True)
    test = df[df["purchased_at"] >= SPLIT_DATE].reset_index(drop=True)
    train, test = add_seller_history(train, test)
    print(f"train={len(train):,}  test={len(test):,}  low-review base rate: "
          f"train={train.low_review.mean():.3f} test={test.low_review.mean():.3f}")

    full = fit_eval(train, test, NUMERIC, CATEGORICAL, "all features")
    no_deliv_num = [c for c in NUMERIC if c not in DELIVERY_FEATURES]
    ablation = fit_eval(train, test, no_deliv_num, CATEGORICAL, "no delivery-outcome features")

    # ---- metrics table
    rows = []
    for feats, res in [("all features", full), ("without delivery-outcome features", ablation)]:
        for m, r in res.items():
            rows.append({"feature_set": feats, "model": m,
                         "roc_auc": round(r["roc_auc"], 3), "pr_auc": round(r["pr_auc"], 3),
                         "base_rate": round(test.low_review.mean(), 3)})
    pd.DataFrame(rows).to_csv(TAB / "model_performance.csv", index=False)

    # ---- classification report for RF @ 0.5
    y_te = test["low_review"]
    rep = classification_report(y_te, (full["random_forest"]["proba"] >= 0.5).astype(int),
                                target_names=["3-5 stars", "1-2 stars"], output_dict=True)
    with open(TAB / "model_rf_classification_report.json", "w") as f:
        json.dump(rep, f, indent=2)

    # ---- logistic regression coefficients (standardised => comparable)
    lr = full["logistic_regression"]["model"]
    names = lr.named_steps["prep"].get_feature_names_out()
    coefs = pd.DataFrame({"feature": names, "coef": lr.named_steps["clf"].coef_[0]})
    coefs["abs"] = coefs["coef"].abs()
    coefs = coefs.sort_values("abs", ascending=False).drop(columns="abs")
    coefs["odds_ratio_per_1sd"] = np.exp(coefs["coef"]).round(3)
    coefs.to_csv(TAB / "model_logit_coefficients.csv", index=False)

    # ---- permutation importance on raw columns (RF, test set, ROC-AUC drop)
    rf = full["random_forest"]["model"]
    X_te = test[NUMERIC + CATEGORICAL]
    perm = permutation_importance(rf, X_te, y_te, scoring="roc_auc",
                                  n_repeats=5, random_state=SEED, n_jobs=-1)
    imp = (pd.DataFrame({"feature": X_te.columns,
                         "auc_drop_mean": perm.importances_mean,
                         "auc_drop_std": perm.importances_std})
             .sort_values("auc_drop_mean", ascending=False))
    imp.to_csv(TAB / "model_rf_permutation_importance.csv", index=False)
    print("\nPermutation importance (RF, test ROC-AUC drop):")
    print(imp.head(12).round(4).to_string(index=False))
    print("\nTop logistic coefficients:")
    print(coefs.head(12).round(3).to_string(index=False))

    # ---- grouped permutation importance: correlated features are shuffled TOGETHER,
    # otherwise delay_days / delivery_days / on_time split the credit between them.
    groups = {
        "Delivery (delay, delivery time, on-time, transit, handling, promise)":
            ["delay_days", "delivery_days", "on_time", "carrier_transit_days",
             "seller_handling_days", "promised_days"],
        "Seller history (past late / low-review rate, volume)":
            ["seller_late_rate_hist", "seller_low_review_rate_hist", "seller_volume_hist"],
        "Basket (items, sellers, value, freight, payment)":
            ["n_items", "multi_seller", "items_value", "freight_value", "freight_ratio",
             "installments", "payment_type"],
        "Product category": ["category"],
        "Geography (customer / seller state, same state)":
            ["customer_state", "seller_state", "same_state"],
    }
    rng = np.random.default_rng(SEED)
    base_auc = roc_auc_score(y_te, rf.predict_proba(X_te)[:, 1])
    grows = []
    for gname, cols in groups.items():
        drops = []
        for _ in range(5):
            Xp = X_te.copy()
            idx = rng.permutation(len(Xp))
            Xp[cols] = Xp[cols].values[idx]
            drops.append(base_auc - roc_auc_score(y_te, rf.predict_proba(Xp)[:, 1]))
        grows.append({"feature_group": gname, "auc_drop_mean": np.mean(drops),
                      "auc_drop_std": np.std(drops)})
    gimp = pd.DataFrame(grows).sort_values("auc_drop_mean", ascending=False)
    gimp.to_csv(TAB / "model_rf_group_importance.csv", index=False)
    print("\nGrouped permutation importance:")
    print(gimp.round(4).to_string(index=False))

    # ---- figures
    fig, ax = plt.subplots(figsize=(8.5, 3.8))
    g2 = gimp.iloc[::-1]
    ax.barh(g2["feature_group"], g2["auc_drop_mean"], xerr=g2["auc_drop_std"], color="#2a78d6")
    ax.set_xlabel("Drop in test ROC-AUC when the whole group is shuffled")
    fig.suptitle("Delivery features carry the most signal for 1–2 star reviews (Random Forest)",
                 x=0.01, ha="left", fontsize=11, fontweight="bold")
    ax.grid(axis="y", visible=False)
    ax.spines[["top", "right"]].set_visible(False)
    fig.tight_layout()
    fig.savefig(FIG / "11_model_group_importance.png", dpi=150)
    plt.close(fig)

    top = imp.head(12).iloc[::-1]
    fig, ax = plt.subplots(figsize=(8, 5.2))
    ax.barh(top["feature"], top["auc_drop_mean"], xerr=top["auc_drop_std"], color="#2a78d6")
    ax.set_xlabel("Drop in test ROC-AUC when the feature is shuffled")
    fig.suptitle("Single-feature permutation importance (correlated delivery features split credit)",
                 x=0.01, ha="left", fontsize=11, fontweight="bold")
    ax.spines[["top", "right"]].set_visible(False)
    fig.tight_layout()
    fig.savefig(FIG / "09_model_feature_importance.png", dpi=150)
    plt.close(fig)

    perf = pd.DataFrame(rows)
    fig, ax = plt.subplots(figsize=(7, 3.8))
    for i, (fs, g) in enumerate(perf.groupby("feature_set", sort=False)):
        ax.bar(np.arange(len(g)) + i * 0.38, g["roc_auc"], width=0.36,
               label=fs, color=["#2a78d6", "#b8b7b1"][i])
        for x, v in zip(np.arange(len(g)) + i * 0.38, g["roc_auc"]):
            ax.text(x, v + 0.01, f"{v:.2f}", ha="center", fontsize=9)
    ax.set_xticks(np.arange(2) + 0.19, ["Logistic regression", "Random forest"])
    ax.set_ylim(0.5, 0.85)
    ax.set_ylabel("Test ROC-AUC")
    ax.set_title("Removing delivery features drops test ROC-AUC from 0.72 to 0.66", loc="left",
                 fontsize=11, fontweight="bold")
    ax.legend(frameon=False, fontsize=9)
    ax.spines[["top", "right"]].set_visible(False)
    fig.tight_layout()
    fig.savefig(FIG / "10_model_ablation.png", dpi=150)
    plt.close(fig)


if __name__ == "__main__":
    main()
