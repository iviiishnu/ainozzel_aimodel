"""HTTP-level tests against the real Flask app and the real model."""
import io
import json
import os

import cv2
import numpy as np
import pytest

farm_app = pytest.importorskip("farm_app")     # loads the model (~20 s)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


@pytest.fixture(scope="module")
def client():
    farm_app.app.config["TESTING"] = True
    return farm_app.app.test_client()


def jpeg(img):
    return io.BytesIO(cv2.imencode(".jpg", img)[1].tobytes())


def post(client, data, name="x.jpg"):
    return client.post("/api/crop/analyze", data={"file": (data, name)},
                       content_type="multipart/form-data")


def val_paths(cls):
    split = json.load(open(os.path.join(ROOT, "models", "split.json")))["val"]
    for rel in split:
        parts = rel.replace("\\", "/").split("/")
        if parts[0] == cls:
            yield os.path.join(ROOT, "images", *parts)


def leaf_image(cls):
    for path in val_paths(cls):
        if os.path.exists(path):
            return cv2.imread(path)
    pytest.skip("dataset image not available")


def test_health(client):
    r = client.get("/health").get_json()
    assert r["status"] == "ok" and r["model_loaded"] and r["num_classes"] == len(r["classes"])


def test_no_file_field_is_400(client):
    assert client.post("/api/crop/analyze").status_code == 400


def test_wrong_extension_is_400(client):
    assert post(client, io.BytesIO(b"hello"), "a.txt").status_code == 400


def test_corrupt_image_is_400(client):
    assert post(client, io.BytesIO(b"definitely not a jpeg"), "a.jpg").status_code == 400


def test_truncated_jpeg_is_rejected_not_classified(client):
    """Regression: a half-uploaded photo was classified from its grey padding."""
    whole = jpeg(leaf_image("Rust")).getvalue()
    r = post(client, io.BytesIO(whole[: len(whole) // 3]))
    assert r.status_code == 400 and "corrupt" in r.get_json()["error"]


@pytest.mark.parametrize("colour", [0, 128, 255])
def test_plain_frames_are_rejected_as_no_leaf(client, colour):
    r = post(client, jpeg(np.full((300, 300, 3), colour, np.uint8)))
    assert r.status_code == 400 and r.get_json()["error"] == "No leaf detected."


def test_diseased_leaf_returns_spray_and_valid_fields(client):
    r = post(client, jpeg(leaf_image("Rust")))
    j = r.get_json()
    assert r.status_code == 200 and j["status"] == "Diseased" and j["spray_recommended"] is True
    assert 0 <= j["damage_percent"] <= 100 and j["severity"] in ("Low", "Medium", "High")


def test_healthy_leaf_never_sprays(client):
    j = post(client, jpeg(leaf_image("Healthy"))).get_json()
    assert j["spray_recommended"] is False


def test_dark_anthracnose_leaf_is_not_rejected_as_no_leaf(client):
    """Regression: the HSV pre-check rejected ~17% of Anthracnose leaves."""
    import preprocessing as pp
    checked = 0
    for path in val_paths("Anthracnose"):
        img = cv2.imread(path)
        if img is None or pp.leaf_fraction(img) >= pp.MIN_LEAF_FRACTION:
            continue                                    # only the dark ones
        checked += 1
        r = post(client, jpeg(img))
        assert r.status_code == 200, path
        if checked == 5:
            break
    assert checked > 0, "no dark Anthracnose sample found"


def test_uploads_are_cleaned_up(client):
    post(client, jpeg(leaf_image("Rust")))
    assert os.listdir(farm_app.UPLOAD_DIR) == []
