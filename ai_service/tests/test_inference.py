import numpy as np
import pytest

import inference as inf

CLASSES = ["Anthracnose", "Bacterial_Leaf_Spot", "Black_rot", "Downy_Mildew", "Healthy",
           "Leaf_Spot_Blight", "Mosaic_Disease", "Not_Leaf", "Powdery_Mildew", "Rust"]
IMG = np.zeros((224, 224, 3), np.uint8)


@pytest.fixture(autouse=True)
def no_ood(monkeypatch):
    monkeypatch.setattr(inf, "unfamiliar_score", lambda feats, names: None)


def probs(**kw):
    """Probability vector with the given class masses; remainder spread evenly."""
    p = np.zeros(len(CLASSES), np.float32)
    for k, v in kw.items():
        p[CLASSES.index(k)] = v
    rest = max(0.0, 1.0 - p.sum())
    zeros = np.where(p == 0)[0]
    p[zeros] = rest / len(zeros)
    return p


def build(p):
    return inf._build_result(p, np.zeros(1280, np.float32), CLASSES, IMG, 5)


def test_confident_disease_sprays():
    r = build(probs(Rust=0.95))
    assert (r["status"], r["disease"], r["spray_recommended"]) == ("Diseased", "Rust", True)


def test_healthy_never_sprays_and_has_zero_damage():
    r = build(probs(Healthy=0.97))
    assert r["status"] == "Healthy" and not r["spray_recommended"] and r["damage_percent"] == 0.0


def test_not_leaf_never_sprays():
    r = build(probs(Not_Leaf=0.9))
    assert r["status"] == "NotLeaf" and not r["spray_recommended"]


def test_low_confidence_is_uncertain_and_never_sprays():
    r = build(np.full(len(CLASSES), 1 / len(CLASSES), np.float32))
    assert r["status"] == "Uncertain" and not r["spray_recommended"]


def test_disease_below_spray_confidence_does_not_spray():
    r = build(probs(Rust=0.55, Healthy=0.02))          # >= 0.50 but < 0.60
    assert r["status"] == "Uncertain" and not r["spray_recommended"]


def test_disease_with_real_healthy_probability_does_not_spray():
    r = build(probs(Rust=0.80, Healthy=0.15))          # healthy >= 0.10
    assert r["status"] == "Uncertain" and not r["spray_recommended"]


def test_unfamiliar_image_does_not_spray(monkeypatch):
    monkeypatch.setattr(inf, "unfamiliar_score", lambda f, n: (0.6, 0.4))
    r = build(probs(Rust=0.99))
    assert r["status"] == "Uncertain" and not r["spray_recommended"]
    assert r["unfamiliar_score"] == 0.6


def test_familiar_image_still_sprays(monkeypatch):
    monkeypatch.setattr(inf, "unfamiliar_score", lambda f, n: (0.2, 0.4))
    assert build(probs(Rust=0.99))["spray_recommended"] is True


@pytest.mark.parametrize("dmg,label", [(0, "Low"), (14.99, "Low"), (15, "Medium"),
                                       (34.99, "Medium"), (35, "High"), (100, "High")])
def test_severity_bands(dmg, label):
    assert inf.get_severity_label(dmg) == label


def test_all_class_probs_are_percentages_keyed_by_class():
    r = build(probs(Rust=0.9))
    assert set(r["all_class_probs"]) == set(CLASSES)
    assert r["all_class_probs"]["Rust"] == 90.0


# ---- leaf gate -----------------------------------------------------------
T = 0.10


def res(status, conf):
    return {"status": status, "confidence_percent": conf}


def test_gate_enough_plant_colour_always_passes():
    assert inf.leaf_gate_passes(0.5, res("Uncertain", 10), T)


def test_gate_below_hard_floor_never_passes_even_if_model_is_sure():
    assert not inf.leaf_gate_passes(0.0, res("Diseased", 99), T)
    assert not inf.leaf_gate_passes(inf.LEAF_HARD_FRACTION - 1e-6, res("Healthy", 99), T)


@pytest.mark.parametrize("status", ["Diseased", "Healthy"])
def test_gate_dark_leaf_passes_on_confident_leaf_result(status):
    assert inf.leaf_gate_passes(0.05, res(status, 95), T)


@pytest.mark.parametrize("status,conf", [("NotLeaf", 99), ("Uncertain", 99),
                                         ("Diseased", 70), ("Healthy", 84.9)])
def test_gate_dark_frame_rejected_unless_confident_leaf(status, conf):
    assert not inf.leaf_gate_passes(0.05, res(status, conf), T)


# ---- spray rule "score" ---------------------------------------------------
@pytest.fixture
def score_rule(monkeypatch):
    monkeypatch.setattr(inf, "SPRAY_RULE", "score")
    monkeypatch.setattr(inf, "SPRAY_SCORE", 0.70)


def split_diseases():
    """Confidence split between two similar diseases; nothing above 0.40."""
    return probs(Anthracnose=0.38, Leaf_Spot_Blight=0.34, Healthy=0.05, Not_Leaf=0.02)


def test_default_rule_is_confidence_and_drops_split_disease():
    assert inf.SPRAY_RULE == "confidence"
    r = build(split_diseases())
    assert r["status"] == "Uncertain" and not r["spray_recommended"]


def test_score_rule_sprays_when_confidence_is_split_between_diseases(score_rule):
    r = build(split_diseases())
    assert r["status"] == "Diseased" and r["spray_recommended"] is True
    assert r["disease"] == "Anthracnose"                 # most likely disease
    assert r["spray_score_percent"] == 93.0              # 1 - 0.05 - 0.02


def test_score_rule_healthy_leaf_does_not_spray(score_rule):
    r = build(probs(Healthy=0.9))
    assert r["status"] == "Healthy" and not r["spray_recommended"]


def test_score_rule_not_leaf_does_not_spray(score_rule):
    r = build(probs(Not_Leaf=0.6, Rust=0.3))
    assert r["status"] == "NotLeaf" and not r["spray_recommended"]


def test_score_rule_below_threshold_does_not_spray(score_rule):
    r = build(probs(Healthy=0.35, Not_Leaf=0.05, Rust=0.30))    # score 0.60 < 0.70
    assert not r["spray_recommended"]


def test_score_rule_still_blocks_unfamiliar_images(score_rule, monkeypatch):
    monkeypatch.setattr(inf, "unfamiliar_score", lambda f, n: (0.6, 0.4))
    r = build(probs(Rust=0.99))
    assert r["status"] == "Uncertain" and not r["spray_recommended"]


def test_score_rule_boundary(score_rule):
    def vec(healthy, rust):                      # exact masses, nothing spread around
        p = np.zeros(len(CLASSES), np.float32)
        p[CLASSES.index("Healthy")], p[CLASSES.index("Rust")] = healthy, rust
        return p

    assert build(vec(0.29, 0.71))["spray_recommended"]            # score 0.71
    assert not build(vec(0.31, 0.69))["spray_recommended"]        # score 0.69


def test_spray_score_helper():
    p = probs(Healthy=0.2, Not_Leaf=0.1)
    assert inf.spray_score(p, CLASSES) == pytest.approx(0.7)
