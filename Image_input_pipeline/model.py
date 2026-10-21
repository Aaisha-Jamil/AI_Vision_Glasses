import os
import cv2
import numpy as np

ROOT_DIR = os.path.dirname(os.path.abspath(__file__))

class PrivacyModel:
    def __init__(
        self,
        model_path=None,
        conf_threshold=0.15,
        default_target="full_body",
        blur_kernel_size=(65, 65),
        blue_color=(220, 110, 40),
        opacity=0.88,
    ):
        self.conf_threshold = conf_threshold
        self.default_target = default_target
        self.blur_kernel_size = blur_kernel_size
        self.blue_color = blue_color
        self.opacity = opacity
        self.model = None

        if model_path is None:
            candidates = [
                os.path.join(ROOT_DIR, "best.pt"),
                "best.pt"
            ]
            for p in candidates:
                if os.path.exists(p):
                    model_path = p
                    break

        self.model_path = model_path
        self._load_model()

    def _load_model(self):
        if not self.model_path or not os.path.exists(self.model_path):
            print(f"[model.py Warning]: Model weights '{self.model_path}' not found. Privacy blur will be bypassed.")
            return

        try:
            from ultralytics import YOLO
            self.model = YOLO(self.model_path)
            print(f"[model.py SUCCESS]: Loaded YOLO Person Segmentation model from '{self.model_path}'.")
        except Exception as e:
            print(f"[model.py Error]: Failed loading YOLO model ({e}).")
            self.model = None

    def apply_privacy_blur(self, raw_frame, timestamp=None, target_mode=None):
        """
        Stage 1: YOLO Person Detection & Solid Privacy Shielding (In-Memory Only)
        """
        if raw_frame is None:
            return None, 0, None

        if target_mode is None:
            target_mode = self.default_target

        h, w = raw_frame.shape[:2]

        if self.model is None or target_mode == "off":
            return raw_frame.copy(), 0, np.zeros((h, w), dtype=np.uint8)

        try:
            results = self.model.predict(
                source=raw_frame,
                conf=self.conf_threshold,
                verbose=False
            )[0]
        except Exception as e:
            print(f"[model.py Predict Error]: {e}")
            return raw_frame.copy(), 0, np.zeros((h, w), dtype=np.uint8)

        if len(results.boxes) == 0:
            return raw_frame.copy(), 0, np.zeros((h, w), dtype=np.uint8)

        human_count = len(results.boxes)
        combined_human_mask = np.zeros((h, w), dtype=np.uint8)

        has_masks = (results.masks is not None and len(results.masks) > 0)
        polygons = results.masks.xy if has_masks else [[] for _ in results.boxes]

        for idx, box in enumerate(results.boxes):
            x1, y1, x2, y2 = map(int, box.xyxy[0].cpu().numpy())
            x1, y1 = max(0, x1), max(0, y1)
            x2, y2 = min(w, x2), min(h, y2)
            box_h = max(1, y2 - y1)

            polygon = polygons[idx] if idx < len(polygons) else []
            person_mask = np.zeros((h, w), dtype=np.uint8)

            if len(polygon) > 0:
                cv2.fillPoly(person_mask, [np.array(polygon, dtype=np.int32)], 255)
            else:
                cv2.ellipse(
                    person_mask,
                    ((x1 + x2) // 2, (y1 + y2) // 2),
                    (max(1, (x2 - x1) // 2), max(1, (y2 - y1) // 2)),
                    0, 0, 360, 255, -1
                )

            if target_mode == "face_only":
                head_cutoff_y = min(h, max(0, int(y1 + 0.28 * box_h)))
                person_mask[head_cutoff_y:, :] = 0

            combined_human_mask = cv2.bitwise_or(combined_human_mask, person_mask)

        blurred_frame = cv2.GaussianBlur(raw_frame, self.blur_kernel_size, sigmaX=35)
        blue_canvas = np.full((h, w, 3), self.blue_color, dtype=np.uint8)
        frosted_blue_layer = cv2.addWeighted(
            blue_canvas, self.opacity, blurred_frame, (1.0 - self.opacity), 0
        )

        alpha = (combined_human_mask / 255.0)[:, :, np.newaxis]
        final_output = (
            frosted_blue_layer * alpha + raw_frame * (1.0 - alpha)
        ).astype(np.uint8)

        return final_output, human_count, combined_human_mask

_privacy_service = None

def apply_privacy_blur(raw_frame, timestamp=None, target_mode="full_body"):
    global _privacy_service
    if _privacy_service is None:
        _privacy_service = PrivacyModel()
    return _privacy_service.apply_privacy_blur(raw_frame, timestamp=timestamp, target_mode=target_mode)