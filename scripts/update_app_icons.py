import os
import subprocess
import numpy as np
from PIL import Image

def crop_icon_content(img, padding=10):
    """Detects content boundary (ignoring white background or transparent background), crops and centers square."""
    img_rgba = img.convert("RGBA")
    arr = np.array(img_rgba)
    r, g, b, a = arr[:, :, 0], arr[:, :, 1], arr[:, :, 2], arr[:, :, 3]
    
    # Non-background mask: not transparent and not white
    is_transparent = a < 10
    is_white = (r > 240) & (g > 240) & (b > 240)
    
    non_bg_mask = (~is_transparent) & (~is_white)
    y_indices, x_indices = np.where(non_bg_mask)
    
    if len(x_indices) == 0:
        y_indices, x_indices = np.where(~is_transparent)
        
    if len(x_indices) == 0:
        print("Warning: No visible icon content detected, using original image.")
        return img

    min_x, max_x = int(x_indices.min()), int(x_indices.max())
    min_y, max_y = int(y_indices.min()), int(y_indices.max())

    width = max_x - min_x + 1
    height = max_y - min_y + 1
    size = max(width, height)

    center_x = (min_x + max_x) // 2
    center_y = (min_y + max_y) // 2
    
    half_size = size // 2 + padding

    crop_left = max(0, center_x - half_size)
    crop_top = max(0, center_y - half_size)
    crop_right = min(img.width, center_x + half_size)
    crop_bottom = min(img.height, center_y + half_size)

    print(f"Original image size: {img.size}, mode: {img.mode}")
    print(f"Detected content bounding box: X=[{min_x}, {max_x}], Y=[{min_y}, {max_y}]")
    print(f"Crop box: ({crop_left}, {crop_top}, {crop_right}, {crop_bottom}) -> size ({crop_right - crop_left}, {crop_bottom - crop_top})")

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
    cropped_img = crop_icon_content(source_img, padding=10)

    # Ensure assets dir exists
    os.makedirs(assets_dir, exist_ok=True)

    # Update voice_app/assets/app_icon.png and app_icon_macos.png
    app_icon_path = os.path.join(assets_dir, "app_icon.png")
    app_icon_macos_path = os.path.join(assets_dir, "app_icon_macos.png")

    target_size = (1024, 1024)
    resized_1024 = cropped_img.resize(target_size, Image.Resampling.LANCZOS)
    
    resized_1024.save(app_icon_path, "PNG")
    print(f"Saved app_icon: {app_icon_path}")

    resized_1024.save(app_icon_macos_path, "PNG")
    print(f"Saved app_icon_macos: {app_icon_macos_path}")

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
