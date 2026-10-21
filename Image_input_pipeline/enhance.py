import cv2
import numpy as np

def remove_shadows_and_level_illumination(image):
    rgb_planes = cv2.split(image)
    result_planes = []
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (25, 25))

    for plane in rgb_planes:
        dilated = cv2.dilate(plane, kernel)
        bg = cv2.medianBlur(dilated, 21)
        diff = 255 - cv2.absdiff(plane, bg)
        norm = cv2.normalize(diff, None, alpha=0, beta=255, norm_type=cv2.NORM_MINMAX)
        result_planes.append(norm)

    return cv2.merge(result_planes)

def enhance_magic_color(image):
    denoised = cv2.bilateralFilter(image, d=7, sigmaColor=25, sigmaSpace=25)
    leveled = remove_shadows_and_level_illumination(denoised)

    lab = cv2.cvtColor(leveled, cv2.COLOR_BGR2LAB)
    l, a, b = cv2.split(lab)
    clahe = cv2.createCLAHE(clipLimit=1.6, tileGridSize=(8, 8))
    cl = clahe.apply(l)

    cl_float = cl.astype(np.float32)
    cl_boosted = np.clip(1.12 * cl_float - 12, 0, 255).astype(np.uint8)

    enhanced_lab = cv2.merge([cl_boosted, a, b])
    enhanced_bgr = cv2.cvtColor(enhanced_lab, cv2.COLOR_LAB2BGR)

    gaussian = cv2.GaussianBlur(enhanced_bgr, (0, 0), sigmaX=1.2, sigmaY=1.2)
    sharpened = cv2.addWeighted(enhanced_bgr, 1.35, gaussian, -0.35, 0)
    return np.clip(sharpened, 0, 255).astype(np.uint8)

def enhance_clean_bw(image):
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    denoised = cv2.bilateralFilter(gray, d=7, sigmaColor=35, sigmaSpace=35)

    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (25, 25))
    dilated = cv2.dilate(denoised, kernel)
    bg = cv2.medianBlur(dilated, 21)
    diff = 255 - cv2.absdiff(denoised, bg)
    norm = cv2.normalize(diff, None, alpha=0, beta=255, norm_type=cv2.NORM_MINMAX)

    thresh = cv2.adaptiveThreshold(norm, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY, 17, 8)
    return cv2.cvtColor(thresh, cv2.COLOR_GRAY2BGR)

def enhance_lowres_video(image):
    denoised = cv2.bilateralFilter(image, d=9, sigmaColor=40, sigmaSpace=40)
    leveled = remove_shadows_and_level_illumination(denoised)

    lab = cv2.cvtColor(leveled, cv2.COLOR_BGR2LAB)
    l, a, b = cv2.split(lab)
    clahe = cv2.createCLAHE(clipLimit=1.3, tileGridSize=(6, 6))
    cl = clahe.apply(l)

    enhanced_lab = cv2.merge([cl, a, b])
    enhanced_bgr = cv2.cvtColor(enhanced_lab, cv2.COLOR_LAB2BGR)

    blur = cv2.GaussianBlur(enhanced_bgr, (3, 3), 0.8)
    sharpened = cv2.addWeighted(enhanced_bgr, 1.2, blur, -0.2, 0)
    return np.clip(sharpened, 0, 255).astype(np.uint8)

def enhance_slide(image, timestamp=None, mode="magic_color", human_mask=None):
    """
    Stage 2: CamScanner Image Clarification (In-Memory Only)
    """
    if image is None:
        return None

    if human_mask is None:
        b, g, r = cv2.split(image)
        human_mask = ((b.astype(int) - r.astype(int) > 35) & (b > 110)).astype(np.uint8) * 255

    has_human = np.any(human_mask > 0)

    if has_human:
        board_canvas = image.copy()
        board_canvas[human_mask > 0] = [245, 245, 245]
    else:
        board_canvas = image

    if mode == "clean_bw":
        enhanced_board = enhance_clean_bw(board_canvas)
    elif mode == "lowres_smooth":
        enhanced_board = enhance_lowres_video(board_canvas)
    else:
        enhanced_board = enhance_magic_color(board_canvas)

    if has_human:
        final_enhanced = enhanced_board.copy()
        final_enhanced[human_mask > 0] = image[human_mask > 0]
    else:
        final_enhanced = enhanced_board

    return final_enhanced