"""
Live webcam test — what the tablet's Live Scan would decide, on this PC.
=======================================================================
Runs every webcam frame through the same steps as the app's Live Scan
(crop to leaf → model → Not_Leaf / unfamiliar / spray rules, single frame, no
TTA) and shows the decision on screen, so you can hold a real leaf, a
leaf-print shirt, a hand … in front of the USB camera and see what happens.

It is also the quickest way to collect REAL Not_Leaf training images: point
the camera at something that is not a crop leaf and press N. Frames land in
images/Not_Leaf/real_*.jpg, which make_not_leaf.py keeps and train_model.py
uses. Then retrain (see README).

Usage:
    .\\.venv\\Scripts\\python live_test.py              # camera 0
    .\\.venv\\Scripts\\python live_test.py --camera 1

Keys:
    N      save this frame as Not_Leaf (shirt, hand, printed leaf …)
    B      burst: save the next 20 frames as Not_Leaf (move the shirt around)
    S      save this frame to captures/ (to look at later)
    C      swap red/blue (if the USB camera shows wrong colours)
    Space  pause / resume
    Q/Esc  quit
"""

import argparse
import os
import time

import cv2
import numpy as np

from inference import load_class_names, load_keras_model, predict_single
from preprocessing import crop_to_leaf

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
NOT_LEAF_DIR = os.path.join(BASE_DIR, "images", "Not_Leaf")
CAPTURE_DIR = os.path.join(BASE_DIR, "captures")
CONFIRM_FRAMES = int(os.getenv("CONFIRM_FRAMES", "2"))   # same rule as the app
BURST = 20

_COLOURS = {  # BGR
    "Diseased": (40, 40, 230),
    "Healthy": (60, 180, 60),
    "NotLeaf": (200, 140, 40),
    "Uncertain": (0, 170, 230),
}


def _save(frame, folder, prefix):
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"{prefix}{time.strftime('%Y%m%d_%H%M%S')}_"
                                f"{int(time.time() * 1000) % 1000:03d}.jpg")
    cv2.imwrite(path, frame, [cv2.IMWRITE_JPEG_QUALITY, 92])
    return path


def _draw(frame, crop, result, streak, fps, note):
    out = frame.copy()
    h, w = out.shape[:2]
    status = result["status"]
    colour = _COLOURS.get(status, (200, 200, 200))
    spray = status == "Diseased" and streak >= CONFIRM_FRAMES

    # What the model actually sees (the leaf crop), top-right
    side = h // 3
    out[10:10 + side, w - side - 10:w - 10] = cv2.resize(crop, (side, side))
    cv2.rectangle(out, (w - side - 10, 10), (w - 10, 10 + side), (255, 255, 255), 2)
    cv2.putText(out, "model input", (w - side - 5, 30 + side),
                cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2)

    # Decision banner
    cv2.rectangle(out, (0, 0), (w - side - 20, 95), (0, 0, 0), -1)
    title = f"{status}: {result['disease']}" if status == "Diseased" else status
    cv2.putText(out, title, (12, 40), cv2.FONT_HERSHEY_SIMPLEX, 1.2, colour, 3)
    line2 = (f"conf {result['confidence_percent']:.0f}%   damage "
             f"{result['damage_percent']:.0f}%")
    if "unfamiliar_score" in result:
        line2 += f"   unfamiliar {result['unfamiliar_score']:.2f}"
    cv2.putText(out, line2, (12, 75), cv2.FONT_HERSHEY_SIMPLEX, 0.65,
                (230, 230, 230), 2)

    # Spray decision with the frames-in-a-row rule
    if status == "Diseased":
        msg = ("WOULD SPRAY" if spray
               else f"diseased {streak}/{CONFIRM_FRAMES} frames - not yet")
    else:
        msg = "no spray"
    cv2.putText(out, msg, (12, h - 20), cv2.FONT_HERSHEY_SIMPLEX, 1.0,
                (0, 0, 255) if spray else (230, 230, 230), 3)

    # Top-3 class probabilities
    probs = sorted(result["all_class_probs"].items(), key=lambda kv: -kv[1])[:3]
    for i, (name, p) in enumerate(probs):
        cv2.putText(out, f"{name} {p:.0f}%", (12, 130 + 28 * i),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.65, (255, 255, 255), 2)

    cv2.putText(out, f"{fps:.1f} fps   N=not leaf  B=burst  S=save  C=colours  "
                     f"Space=pause  Q=quit", (12, h - 60),
                cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 1)
    if note:
        cv2.putText(out, note, (12, h - 95), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                    (0, 255, 255), 2)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--camera", type=int, default=0)
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--model", default=None, help="model file (default: same as server)")
    args = ap.parse_args()

    model = load_keras_model(model_path=args.model)
    class_names = load_class_names()

    cap = cv2.VideoCapture(args.camera, cv2.CAP_DSHOW if os.name == "nt" else cv2.CAP_ANY)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, args.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, args.height)
    if not cap.isOpened():
        raise SystemExit(f"Camera {args.camera} not found. Try --camera 1.")

    swap, paused, streak, burst_left = False, False, 0, 0
    note, note_until, fps, t_prev = "", 0.0, 0.0, time.time()
    shown = None
    print(__doc__.split("Keys:")[1])

    while True:
        if not paused:
            ok, frame = cap.read()
            if not ok:
                print("Camera read failed")
                break
            if swap:
                frame = frame[:, :, ::-1].copy()

            result = predict_single(model, frame, class_names)
            streak = streak + 1 if result["status"] == "Diseased" else 0
            crop = crop_to_leaf(frame)

            if burst_left:
                _save(frame, NOT_LEAF_DIR, "real_")
                burst_left -= 1
                note, note_until = f"burst: {BURST - burst_left}/{BURST} saved", time.time() + 1.5

            now = time.time()
            fps = 0.8 * fps + 0.2 / max(now - t_prev, 1e-3)
            t_prev = now
            shown = _draw(frame, crop, result, streak, fps,
                          note if time.time() < note_until else "")
            last_frame = frame
        cv2.imshow("AI Nozzle - live test", shown)

        key = cv2.waitKey(1) & 0xFF
        if key in (ord("q"), 27):
            break
        if key == ord(" "):
            paused = not paused
        elif key == ord("c"):
            swap = not swap
            note, note_until = f"red/blue swap {'ON' if swap else 'OFF'}", time.time() + 2
        elif key == ord("n"):
            p = _save(last_frame, NOT_LEAF_DIR, "real_")
            note, note_until = f"saved Not_Leaf: {os.path.basename(p)}", time.time() + 2
            print("Not_Leaf ->", p)
        elif key == ord("b"):
            burst_left = BURST
        elif key == ord("s"):
            p = _save(last_frame, CAPTURE_DIR, "capture_")
            note, note_until = f"saved {os.path.basename(p)}", time.time() + 2
            print("capture ->", p)

    cap.release()
    cv2.destroyAllWindows()
    n = len([f for f in os.listdir(NOT_LEAF_DIR) if f.startswith("real_")]) \
        if os.path.isdir(NOT_LEAF_DIR) else 0
    print(f"\nReal Not_Leaf images now: {n}. Retrain when you have 200+ "
          "(see README: train_model.py → convert_tflite.py → copy to the app).")


if __name__ == "__main__":
    main()
