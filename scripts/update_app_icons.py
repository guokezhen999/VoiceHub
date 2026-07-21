import os
import subprocess
import numpy as np
from PIL import Image, ImageDraw

def apply_macos_rounded_corners(img, radius_ratio=0.2237):
    """Apply macOS Big Sur+ style rounded-rect mask (transparent corners).

    Apple HIG uses ~22.37% of icon size as the continuous corner radius.
    """
    img_rgba = img.convert("RGBA")
    w, h = img_rgba.size
    size = min(w, h)
    radius = max(1, int(size * radius_ratio))

    # Build anti-aliased rounded-rect alpha mask (4x supersample then downscale)
    scale = 4
    mask_big = Image.new("L", (w * scale, h * scale), 0)
    draw = ImageDraw.Draw(mask_big)
    draw.rounded_rectangle(
        (0, 0, w * scale - 1, h * scale - 1),
        radius=radius * scale,
        fill=255,
    )
    mask = mask_big.resize((w, h), Image.Resampling.LANCZOS)

    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    out.paste(img_rgba, (0, 0), mask)
    return out


def crop_icon_content(img, padding_ratio=0.05):
    """Detects content boundary (transparent, white, or opaque gradient background), crops and centers square."""
    img_rgba = img.convert("RGBA")
    arr = np.array(img_rgba)
    h, w, _ = arr.shape
    
    r, g, b, a = arr[:, :, 0], arr[:, :, 1], arr[:, :, 2], arr[:, :, 3]
    
    # Check transparency
    is_transparent = a < 240
    is_white = (r > 240) & (g > 240) & (b > 240)
    non_bg_alpha = (~is_transparent) & (~is_white)
    
    if np.sum(is_transparent) > (w * h * 0.05):
        # Has meaningful transparency
        y_indices, x_indices = np.where(~is_transparent)
    else:
        # Fully opaque image - use std deviation of 8x8 blocks to detect content vs background
        block_size = 8
        gh, gw = h // block_size, w // block_size
        std_map = np.zeros((gh, gw))
        
        arr_rgb = arr[:, :, :3].astype(float)
        for row in range(gh):
            for col in range(gw):
                patch = arr_rgb[row*block_size:(row+1)*block_size, col*block_size:(col+1)*block_size, :]
                std_map[row, col] = patch.std(axis=(0,1)).mean()
        
        # Mask out small isolated watermarks in corners (e.g., bottom-right outer 20%)
        main_mask = std_map > 4.0
        main_mask[int(gh*0.8):, int(gw*0.8):] = False
        
        y_idx, x_idx = np.where(main_mask)
        if len(x_idx) == 0:
            y_indices, x_indices = np.where(non_bg_alpha)
        else:
            min_y, max_y = int(y_idx.min() * block_size), int((y_idx.max() + 1) * block_size)
            min_x, max_x = int(x_idx.min() * block_size), int((x_idx.max() + 1) * block_size)
            
            cx = (min_x + max_x) // 2
            cy = (min_y + max_y) // 2
            content_size = max(max_x - min_x, max_y - min_y)
            padding = int(content_size * padding_ratio)
            half_side = content_size // 2 + padding
            
            final_side = max(half_side * 2, 10)
            crop_left = max(0, min(w - final_side, cx - half_side))
            crop_top = max(0, min(h - final_side, cy - half_side))
            crop_right = crop_left + final_side
            crop_bottom = crop_top + final_side
            
            print(f"Original image size: {img.size}")
            print(f"Detected content bounding box: X=[{min_x}, {max_x}], Y=[{min_y}, {max_y}]")
            print(f"Crop box: ({crop_left}, {crop_top}, {crop_right}, {crop_bottom}) -> size ({final_side}, {final_side})")
            return img.crop((crop_left, crop_top, crop_right, crop_bottom))

    if len(x_indices) == 0:
        print("Warning: No visible icon content detected, using original image.")
        return img

    min_x, max_x = int(x_indices.min()), int(x_indices.max())
    min_y, max_y = int(y_indices.min()), int(y_indices.max())
    
    cx = (min_x + max_x) // 2
    cy = (min_y + max_y) // 2
    content_size = max(max_x - min_x + 1, max_y - min_y + 1)
    padding = int(content_size * padding_ratio)
    half_side = content_size // 2 + padding
    
    final_side = max(half_side * 2, 10)
    crop_left = max(0, min(w - final_side, cx - half_side))
    crop_top = max(0, min(h - final_side, cy - half_side))
    crop_right = crop_left + final_side
    crop_bottom = crop_top + final_side
    
    print(f"Original image size: {img.size}")
    print(f"Detected content bounding box: X=[{min_x}, {max_x}], Y=[{min_y}, {max_y}]")
    print(f"Crop box: ({crop_left}, {crop_top}, {crop_right}, {crop_bottom}) -> size ({final_side}, {final_side})")
    return img.crop((crop_left, crop_top, crop_right, crop_bottom))

def main():
    root_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    images_dir = os.path.join(root_dir, "images")
    voice_app_dir = os.path.join(root_dir, "voice_app")
    assets_dir = os.path.join(voice_app_dir, "assets")

    # Candidates for source icon
    candidates = [
        os.path.join(images_dir, "已移除背景的icon.png"),
        os.path.join(images_dir, "icon.png"),
    ]
    source_icon_path = None
    for cand in candidates:
        if os.path.exists(cand):
            source_icon_path = cand
            break

    if not source_icon_path:
        # Check any png in images_dir
        for f in os.listdir(images_dir):
            if f.lower().endswith(".png"):
                source_icon_path = os.path.join(images_dir, f)
                break

    if not source_icon_path:
        print(f"Error: No source icon PNG found in {images_dir}")
        return

    print(f"Loading updated source icon: {source_icon_path}")
    source_img = Image.open(source_icon_path)
    
    # Also save/copy as images/icon.png for consistency
    icon_png_standard = os.path.join(images_dir, "icon.png")
    if source_icon_path != icon_png_standard:
        source_img.save(icon_png_standard, "PNG")
        print(f"Updated standard source icon path: {icon_png_standard}")
    
    # Crop to content
    cropped_img = crop_icon_content(source_img)

    # Ensure assets dir exists
    os.makedirs(assets_dir, exist_ok=True)

    # Update voice_app/assets/app_icon.png and app_icon_macos.png
    app_icon_path = os.path.join(assets_dir, "app_icon.png")
    app_icon_macos_path = os.path.join(assets_dir, "app_icon_macos.png")

    target_size = (1024, 1024)
    resized_1024 = cropped_img.resize(target_size, Image.Resampling.LANCZOS)
    
    resized_1024.save(app_icon_path, "PNG")
    print(f"Saved app_icon: {app_icon_path}")

    # macOS icons use transparent rounded corners (system squircle style)
    macos_icon = apply_macos_rounded_corners(resized_1024)
    macos_icon.save(app_icon_macos_path, "PNG")
    print(f"Saved app_icon_macos (rounded): {app_icon_macos_path}")

    # Update Windows app_icon.ico
    win_ico_path = os.path.join(voice_app_dir, "windows", "runner", "resources", "app_icon.ico")
    if os.path.exists(os.path.dirname(win_ico_path)):
        sizes = [(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
        cropped_img.save(win_ico_path, format="ICO", sizes=sizes)
        print(f"Saved Windows ICO: {win_ico_path}")

    # Run flutter_launcher_icons
    print("\nRunning flutter_launcher_icons...")
    try:
        res = subprocess.run(
            ["flutter", "pub", "run", "flutter_launcher_icons"],
            cwd=voice_app_dir,
            capture_output=True,
            text=True,
            check=True
        )
        print(res.stdout)
    except subprocess.CalledProcessError as e:
        print("flutter_launcher_icons error:", e.stderr)

    print("\nAll icons updated with new background-removed icon successfully!")

if __name__ == "__main__":
    main()
