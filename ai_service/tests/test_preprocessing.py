import numpy as np
import cv2
import pytest

import preprocessing as pp


def solid(bgr, size=(240, 320)):
    img = np.zeros((*size, 3), np.uint8)
    img[:] = bgr
    return img


GREEN = (40, 160, 50)        # BGR leaf green
BROWN = (30, 70, 140)        # BGR rust/brown lesion
GREY = (128, 128, 128)
BLACK = (0, 0, 0)
WHITE = (255, 255, 255)


def test_green_image_is_all_leaf_and_undamaged():
    img = solid(GREEN)
    assert pp.leaf_fraction(img) > 0.95
    assert pp.estimate_damage_percent(img) < 1.0


def test_brown_image_is_leaf_tissue_and_fully_damaged():
    img = solid(BROWN)
    assert pp.leaf_fraction(img) > 0.95
    assert pp.estimate_damage_percent(img) > 95.0


def test_grey_black_white_are_not_leaves():
    for colour in (GREY, BLACK, WHITE):
        img = solid(colour)
        assert pp.leaf_fraction(img) == 0.0
        assert not pp.is_leaf_present(img)
        assert pp.estimate_damage_percent(img) == 0.0


def test_half_green_half_brown_is_about_half_damaged():
    img = solid(GREEN)
    img[:, 160:] = BROWN
    assert 40 <= pp.estimate_damage_percent(img) <= 60


def test_is_leaf_present_none_is_false():
    assert pp.is_leaf_present(None) is False


def test_preprocess_shape_dtype_range():
    x = pp.preprocess_for_inference(solid(GREEN))
    assert x.shape == (1, 224, 224, 3)
    assert x.dtype == np.float32
    assert 0.0 <= x.min() and x.max() <= 1.0


def test_preprocess_is_rgb_not_bgr():
    # pure blue in BGR must end up in the LAST channel of the RGB tensor
    x = pp.preprocess_for_inference(solid((255, 0, 0)))
    assert x[0, 0, 0, 2] == 1.0 and x[0, 0, 0, 0] == 0.0


def test_load_bgr_accepts_bytes_array_gray_and_bgra():
    ok, buf = cv2.imencode(".png", solid(GREEN))
    assert pp.load_bgr(buf.tobytes()).shape == (240, 320, 3)
    assert pp.load_bgr(np.zeros((10, 10), np.uint8)).shape == (10, 10, 3)
    assert pp.load_bgr(np.zeros((10, 10, 4), np.uint8)).shape == (10, 10, 3)


@pytest.mark.parametrize("bad,exc", [(b"not an image", ValueError), (123, TypeError)])
def test_load_bgr_rejects_junk(bad, exc):
    with pytest.raises(exc):
        pp.load_bgr(bad)


def test_tta_variant_counts():
    for n in range(1, 6):
        v = pp.generate_tta_variants(solid(GREEN), n_variants=n)
        assert len(v) == n and all(a.shape == (1, 224, 224, 3) for a in v)


def test_aggregate_averages_and_rejects_empty():
    a = np.array([1.0, 0.0])
    b = np.array([0.0, 1.0])
    assert np.allclose(pp.aggregate_predictions([a, b]), [0.5, 0.5])
    with pytest.raises(ValueError):
        pp.aggregate_predictions([])


def test_crop_to_leaf_wide_frame_becomes_square_around_leaf():
    frame = solid(GREY, (360, 640))
    frame[100:260, 400:560] = GREEN            # leaf on the right
    out = pp.crop_to_leaf(frame)
    assert out.shape[0] == out.shape[1] < 360
    assert (out == np.array(GREEN, np.uint8)).all(axis=-1).mean() > 0.5


def test_crop_to_leaf_without_green_falls_back_to_centre_square():
    out = pp.crop_to_leaf(solid(GREY, (360, 640)))
    assert out.shape[:2] == (360, 360)


def test_crop_to_leaf_square_closeup_untouched():
    img = solid(GREEN, (300, 300))
    assert pp.crop_to_leaf(img) is img
