"""The explainer is optional, sends only report data, and is checked for invented numbers."""
import json

from mindbridge.explain import assert_clean, build_payload, explain, unknown_numbers


def test_skips_cleanly_without_key(report, built, monkeypatch, capsys, tmp_path):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    assert explain(report, built[0], tmp_path / "x.md") == 0
    assert "skipping" in capsys.readouterr().out
    assert not (tmp_path / "x.md").exists()


def test_payload_has_no_terraform_or_ids(report, built):
    payload = build_payload(report, built[0])
    text = json.dumps(payload)
    assert_clean(text)
    assert "facts" not in payload and "fact_checks" not in payload
    assert "tfvars" not in text and "aws_instance" not in text and "terraform/" not in text
    assert {c["id"] for c in payload["components"]} == set(built[0].components)


def test_assert_clean_catches_identifiers():
    for bad in ("123456789012", "a@b.io", "00000000-0000-0000-0000-000000000000"):
        try:
            assert_clean(bad)
        except ValueError:
            continue
        raise AssertionError(bad)


def test_number_guard():
    payload = json.dumps({"severity": 290.0, "impact_pct": 50.0, "recovery_s": 90})
    assert unknown_numbers("Severity 290, 50% loss, back in 90 s", payload) == []
    assert unknown_numbers("about 45 s", payload) == ["45"]
