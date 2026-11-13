"""Make the README figures from outputs/tables/*.csv  ->  outputs/figures/*.png

Usage:  python src/make_charts.py   (run after src/run_sql.py)
"""
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import seaborn as sns

ROOT = Path(__file__).resolve().parents[1]
TAB = ROOT / "outputs" / "tables"
FIG = ROOT / "outputs" / "figures"

BLUE, ORANGE, GREY, INK, MUTED = "#2a78d6", "#eb6834", "#b8b7b1", "#0b0b0b", "#52514e"
plt.rcParams.update({
    "font.size": 10, "axes.titlesize": 12, "axes.titleweight": "bold",
    "axes.titlelocation": "left", "axes.edgecolor": "#d9d8d3", "axes.labelcolor": MUTED,
    "xtick.color": MUTED, "ytick.color": MUTED, "axes.spines.top": False,
    "axes.spines.right": False, "axes.grid": True, "grid.color": "#ecebe7",
    "grid.linewidth": 0.8, "axes.axisbelow": True, "figure.dpi": 150,
})


def t(name):
    return pd.read_csv(TAB / f"{name}.csv")


def save(fig, name):
    fig.tight_layout()
    fig.savefig(FIG / name, dpi=150, bbox_inches="tight")
    plt.close(fig)


def funnel():
    f = t("funnel_stages")
    fig, ax = plt.subplots(figsize=(8, 3.6))
    ax.barh(f["stage"][::-1], f["orders"][::-1], color=BLUE, height=0.6)
    for y, (o, p) in enumerate(zip(f["orders"][::-1], f["pct_of_placed"][::-1])):
        ax.text(o + 800, y, f"{o:,}  ({p:.1f}%)", va="center", color=INK, fontsize=9)
    ax.set_xlim(0, f["orders"].max() * 1.25)
    ax.set_xlabel("Orders (purchased Jan 2017 – Aug 2018)")
    ax.grid(axis="y", visible=False)
    ax.set_title("The order funnel barely leaks: 96.4% of orders are delivered and reviewed")
    save(fig, "01_funnel.png")


def stage_times():
    s = t("funnel_stage_times")
    s = s[~s["transition"].str.contains("total")]
    fig, ax = plt.subplots(figsize=(8, 3.4))
    y = np.arange(len(s))[::-1]
    ax.barh(y, s["median_days"], color=BLUE, height=0.55, label="Median")
    ax.scatter(s["p90_days"], y, color=ORANGE, s=40, zorder=3, label="90th percentile")
    for yy, m, p in zip(y, s["median_days"], s["p90_days"]):
        ax.text(max(m, p) + 0.4, yy, f"median {m:.1f}d · p90 {p:.1f}d", va="center", fontsize=9)
    ax.set_yticks(y, s["transition"])
    ax.set_xlim(0, s["p90_days"].max() * 1.45)
    ax.set_xlabel("Days")
    ax.grid(axis="y", visible=False)
    ax.legend(frameon=False, loc="lower right")
    ax.set_title("Time is lost in transit: shipped → delivered is the longest, most variable leg")
    save(fig, "02_stage_times.png")


def cohort_heatmap():
    c = t("cohort_retention")
    piv = c[c["month_number"].between(1, 12)].pivot(index="cohort_month", columns="month_number",
                                                     values="pct_retained")
    fig, ax = plt.subplots(figsize=(9, 6))
    sns.heatmap(piv, cmap=sns.light_palette(BLUE, as_cmap=True), annot=True, fmt=".2f",
                annot_kws={"size": 7}, linewidths=1, linecolor="white",
                cbar_kws={"label": "% of cohort buying again in month N"}, ax=ax)
    ax.grid(False)
    ax.set_xlabel("Months since first purchase")
    ax.set_ylabel("Cohort (month of first purchase)")
    ax.set_title("Monthly retention never exceeds ~0.7% after month 0")
    save(fig, "03_cohort_retention_heatmap.png")


def repeat_by_cohort():
    r = t("repeat_purchase_by_cohort")
    fig, ax = plt.subplots(figsize=(9, 3.6))
    x = np.arange(len(r))
    ax.bar(x, r["repeat_rate_90d"], color=BLUE, width=0.65)
    for xi, v in zip(x, r["repeat_rate_90d"]):
        ax.text(xi, v + 0.04, f"{v:.1f}", ha="center", fontsize=8, color=INK)
    ax.set_xticks(x, r["cohort_month"], rotation=45, ha="right")
    ax.set_ylabel("% repeat within 90 days")
    ax.grid(axis="x", visible=False)
    ax.set_title("Only ~1–2% of new customers buy again within 90 days")
    save(fig, "04_repeat_rate_by_cohort.png")


def delay_vs_review():
    d = t("review_by_delay_bucket")
    d["label"] = d["delay_bucket"].str.split(": ").str[1]
    late = d["delay_bucket"].str.contains("late")
    fig, ax = plt.subplots(figsize=(9, 3.8))
    ax.bar(d["label"], d["low_review_rate"], color=np.where(late, ORANGE, BLUE), width=0.65)
    for i, (v, n) in enumerate(zip(d["low_review_rate"], d["orders"])):
        ax.text(i, v + 1.5, f"{v:.0f}%", ha="center", fontsize=9, color=INK)
        ax.text(i, -9, f"n={n:,}", ha="center", fontsize=7, color=MUTED)
    ax.set_ylim(-12, 92)
    ax.axhline(0, color="#d9d8d3", lw=0.8)
    ax.set_ylabel("% of orders with 1–2 stars")
    ax.set_xlabel("Delivered vs estimated date")
    ax.grid(axis="x", visible=False)
    plt.setp(ax.get_xticklabels(), rotation=20, ha="right")
    ax.set_title("One day late and the 1–2 star rate jumps from ~12% to 32%; a week late, ~70–80%")
    save(fig, "05_delay_vs_low_reviews.png")


def monthly_ontime_vs_onestar():
    m = t("metrics_monthly")
    fig, axes = plt.subplots(2, 1, figsize=(9, 5.2), sharex=True)
    x = np.arange(len(m))
    axes[0].plot(x, m["on_time_rate"], color=BLUE, lw=2, marker="o", ms=4)
    axes[0].set_ylabel("On-time rate %")
    axes[0].set_title("When on-time delivery dips (Nov-17, Feb–Mar-18), 1-star reviews spike")
    axes[1].plot(x, m["one_star_rate"], color=ORANGE, lw=2, marker="o", ms=4)
    axes[1].set_ylabel("1-star rate %")
    for ax in axes:
        for lab in ["2017-11", "2018-03"]:
            i = m.index[m["purchase_month"] == lab][0]
            ax.axvspan(i - 0.4, i + 0.4, color="#ecebe7", zorder=0)
    axes[1].set_xticks(x, m["purchase_month"], rotation=45, ha="right")
    corr = m["on_time_rate"].corr(m["one_star_rate"])
    axes[1].text(0.01, 0.92, f"monthly correlation r = {corr:.2f}", transform=axes[1].transAxes,
                 fontsize=9, color=MUTED)
    save(fig, "06_monthly_ontime_vs_onestar.png")


def states():
    s = t("drivers_by_region")
    s = s[s["delivered_orders"] >= 500].sort_values("late_orders", ascending=True)
    total_late = t("drivers_by_region")["late_orders"].sum()
    fig, ax = plt.subplots(figsize=(8.5, 5.5))
    colors = [ORANGE if st in ("RJ", "BA", "CE", "MA", "ES") else BLUE for st in s["customer_state"]]
    ax.barh(s["customer_state"], s["late_orders"], color=colors, height=0.65)
    for y, (lo, ot, lr) in enumerate(zip(s["late_orders"], s["on_time_rate"], s["low_review_rate"])):
        ax.text(lo + 20, y, f"{100*lo/total_late:.0f}% of late · on-time {ot:.0f}% · 1–2★ {lr:.0f}%",
                va="center", fontsize=8)
    ax.set_xlim(0, s["late_orders"].max() * 1.6)
    ax.set_xlabel("Late deliveries (customer state)")
    ax.grid(axis="y", visible=False)
    ax.set_title("RJ is the outlier: 13% of orders, 23% of late deliveries")
    save(fig, "07_late_orders_by_state.png")


def basket():
    b = t("review_by_basket")
    b["label"] = b["basket"].str.split(": ").str[1]
    fig, ax = plt.subplots(figsize=(7.5, 3.4))
    x = np.arange(len(b))
    ax.bar(x - 0.2, b["low_review_rate"], width=0.38, color=BLUE, label="All delivered orders")
    ax.bar(x + 0.2, b["low_review_rate_on_time"], width=0.38, color=GREY, label="On-time orders only")
    for xi, v1, v2, n in zip(x, b["low_review_rate"], b["low_review_rate_on_time"], b["orders"]):
        ax.text(xi - 0.2, v1 + 1, f"{v1:.0f}%", ha="center", fontsize=9)
        ax.text(xi + 0.2, v2 + 1, f"{v2:.0f}%", ha="center", fontsize=9)
    ax.set_xticks(x, [f"{l}\n(n={n:,})" for l, n in zip(b["label"], b["orders"])])
    ax.set_ylabel("% 1–2 star reviews")
    ax.set_ylim(0, 58)
    ax.grid(axis="x", visible=False)
    ax.legend(frameon=False, loc="upper left")
    ax.set_title("Multi-seller baskets get 1–2 stars 47% of the time — even when on time")
    save(fig, "08_basket_vs_low_reviews.png")


if __name__ == "__main__":
    FIG.mkdir(parents=True, exist_ok=True)
    for fn in [funnel, stage_times, cohort_heatmap, repeat_by_cohort, delay_vs_review,
               monthly_ontime_vs_onestar, states, basket]:
        fn()
        print("ok", fn.__name__)
