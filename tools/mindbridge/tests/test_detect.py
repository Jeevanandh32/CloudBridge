"""Predict-mode detectors are pure functions: check each one on small hand-made series."""
import pytest

from mindbridge.detect import (Sample, baseline_deviation, countdown, flap_counter, level, linreg, parse_duration,
                               quota_headroom, time_to_threshold)


def series(values, step=60, signal="x", comp="c", unit="u"):
    return [Sample(i * step, signal, comp, float(v), unit) for i, v in enumerate(values)]


def test_parse_duration():
    assert parse_duration("30m") == 1800
    assert parse_duration("2h") == 7200
    assert parse_duration("7d") == 7 * 86400
    assert parse_duration(90) == 90
    with pytest.raises(ValueError):
        parse_duration("soon")


def test_linreg_exact_line():
    slope, intercept, r2 = linreg([0, 1, 2, 3], [10, 8, 6, 4])
    assert slope == pytest.approx(-2)
    assert intercept == pytest.approx(10)
    assert r2 == pytest.approx(1)


def test_ttt_eta_on_a_clean_drain():
    # 100 free IPs, -2 per minute: at 80 after 10 min, so 0 in another 40 min
    s = series([100 - 2 * i for i in range(11)])
    f = time_to_threshold(s, threshold=0, direction="down", window_s=1800, min_samples=8, r2_min=0.6,
                          horizon_s=6 * 3600, critical_s=1800)
    assert f is not None
    assert f.eta_s == pytest.approx(40 * 60, rel=0.01)
    assert f.severity == "warning"
    assert f.metrics["r2"] == pytest.approx(1)


def test_ttt_gates():
    flat = series([50, 52, 49, 51, 50, 48, 52, 50, 51, 49])
    assert time_to_threshold(flat, threshold=0, direction="down", min_samples=8) is None   # R² gate
    short = series([100, 90, 80])
    assert time_to_threshold(short, threshold=0, direction="down", min_samples=8) is None  # too few
    slow = series([100 - 0.01 * i for i in range(20)])
    assert time_to_threshold(slow, threshold=0, direction="down", min_samples=8, horizon_s=3600) is None  # far away
    rising = series([10 + i for i in range(10)])
    assert time_to_threshold(rising, threshold=0, direction="down", min_samples=8) is None  # wrong way


def test_ttt_threshold_already_reached_is_critical():
    f = time_to_threshold(series([5, 3, 0]), threshold=0, direction="down", min_samples=8)
    assert f.severity == "critical" and f.eta_s == 0


def test_ttt_goes_critical_close_to_threshold():
    s = series([89 - 10 + i for i in range(10)])   # rising 1/min, at 88 -> 90 in ~2 min
    f = time_to_threshold(s, threshold=90, direction="up", min_samples=6, critical_s=1800)
    assert f.severity == "critical"


def test_baseline_needs_warmup_and_k_of_n():
    calm = [30.0 + (0.5 if i % 2 else -0.5) for i in range(20)]
    assert baseline_deviation(series(calm), warmup=12, k_sigma=3, min_delta=2) is None
    one_spike = calm + [45, 30, 30, 30, 30]
    assert baseline_deviation(series(one_spike), warmup=12, k_sigma=3, min_delta=2, k=3, n=5) is None
    shift = calm + [40, 41, 39, 40]
    f = baseline_deviation(series(shift), warmup=12, k_sigma=3, min_delta=2, k=3, n=5)
    assert f is not None and f.metrics["k"] >= 3
    assert f.deviation > 8
    assert baseline_deviation(series(calm[:10] + [50, 50]), warmup=12) is None   # still warming up


def test_baseline_not_poisoned_by_slow_creep():
    # +0.5 per sample after warm-up: a plain EWMA (all samples update it) would follow it
    creep = [30.0 + (0.3 if i % 2 else -0.3) for i in range(15)] + [30 + 0.5 * i for i in range(1, 30)]
    f = baseline_deviation(series(creep), alpha=0.1, warmup=12, k_sigma=4, min_delta=3, min_std=0.5, k=3, n=5)
    assert f is not None
    assert f.metrics["baseline_mean"] < 32


def test_baseline_direction_up_ignores_drops():
    s = [30.0 + (0.5 if i % 2 else -0.5) for i in range(15)] + [10, 10, 10, 10]
    assert baseline_deviation(series(s), warmup=12, k_sigma=3, min_delta=2, direction="up") is None
    assert baseline_deviation(series(s), warmup=12, k_sigma=3, min_delta=2, direction="down") is not None


def test_flap_counter():
    steady = series([1] * 30)
    assert flap_counter(steady, window_s=1800, max_changes=4) is None
    blip = series([1] * 10 + [0, 0] + [1] * 10)          # 2 changes: maintenance, not a flap
    assert flap_counter(blip, window_s=1800, max_changes=4) is None
    flaps = series([1, 0, 1, 0, 1, 0, 1, 1])
    f = flap_counter(flaps, window_s=1800, max_changes=4)
    assert f is not None and f.metrics["changes"] == 6
    # changes older than the window don't count
    old = series([1, 0, 1, 0, 1] + [1] * 40)
    assert flap_counter(old, window_s=1800, max_changes=4) is None


def test_countdown_ages_the_sample():
    s = Sample(0, "domain.expiry_days", "d", 40, "days")
    assert countdown(s, now=0, warn_days=30, critical_days=7) is None
    f = countdown(s, now=15 * 86400, warn_days=30, critical_days=7)   # 25 days left
    assert f.severity == "warning" and f.metrics["days_left"] == pytest.approx(25)
    assert countdown(s, now=35 * 86400, warn_days=30, critical_days=7).severity == "critical"


def test_quota_headroom():
    used = Sample(0, "q", "loc", 2, "count")
    assert quota_headroom(used, 4, warn_free=1, critical_free=0) is None
    assert quota_headroom(used, 3, warn_free=1, critical_free=0).severity == "warning"
    assert quota_headroom(Sample(0, "q", "loc", 3, "count"), 3, warn_free=1, critical_free=0).severity == "critical"


def test_level_k_of_n():
    assert level(series([0, 1, 0]), threshold=0, k=3, n=3) is None
    f = level(series([0, 1, 2, 3]), threshold=0, k=3, n=3, severity="critical")
    assert f.severity == "critical" and f.metrics["k"] == 3
