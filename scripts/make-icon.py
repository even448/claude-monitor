from PIL import Image, ImageDraw, ImageFilter
import math, os

S = 2048
img = Image.new('RGBA', (S, S), (0,0,0,0))
# warm vertical gradient with a hint of coral at bottom
px = img.load()
for y in range(S):
    t = y / (S-1)
    r = int(248*(1-t) + 238*t)
    g = int(243*(1-t) + 226*t)
    b = int(235*(1-t) + 211*t)
    for x in range(S):
        px[x,y] = (r,g,b,255)

mask = Image.new('L',(S,S),0)
md = ImageDraw.Draw(mask)
margin = 200
md.rounded_rectangle((margin,margin,S-margin,S-margin), radius=390, fill=255)
img.putalpha(mask)

# highlight
glow = Image.new('RGBA',(S,S),(0,0,0,0))
gd = ImageDraw.Draw(glow)
gd.ellipse((-500,-700,1500,900), fill=(255,255,255,92))
glow = glow.filter(ImageFilter.GaussianBlur(180))
img = Image.alpha_composite(img, glow)

# pet
pet = Image.new('RGBA',(S,S),(0,0,0,0))
pd = ImageDraw.Draw(pet)
cx, cy = S//2, int(S*0.52)
ray_w, ray_h, ray_off = 232, 520, 240
for i in range(6):
    layer = Image.new('RGBA',(ray_w, ray_h),(0,0,0,0))
    ld = ImageDraw.Draw(layer)
    ld.rounded_rectangle((0,0,ray_w,ray_h), radius=ray_w//2, fill=(201,100,66,255))
    # subtle vertical shading
    shade = Image.new('RGBA',(ray_w,ray_h),(0,0,0,0))
    sd = ImageDraw.Draw(shade)
    for yy in range(ray_h):
        a = int(28 * (yy/ray_h))
        sd.line((0,yy,ray_w,yy), fill=(120,45,26,a))
    layer = Image.alpha_composite(layer, shade)
    layer = layer.rotate(-i*60 + 0, resample=Image.BICUBIC, expand=True)
    lw, lh = layer.size
    # offset outward from center before rotation: place on ray direction
    ang = math.radians(-90 + i*60)
    ox = cx + math.cos(ang)*ray_off - lw/2
    oy = cy + math.sin(ang)*ray_off - lh/2
    pet.alpha_composite(layer, (int(ox), int(oy)))

# center face
face_r = 340
pd.ellipse((cx-face_r, cy-face_r, cx+face_r, cy+face_r), fill=(249,232,216,255), outline=(255,255,255,110), width=5)
# face shading
shade = Image.new('RGBA',(S,S),(0,0,0,0))
sd = ImageDraw.Draw(shade)
sd.ellipse((cx-face_r+80, cy-face_r+350, cx+face_r-80, cy+face_r-20), fill=(214,172,144,50))
shade = shade.filter(ImageFilter.GaussianBlur(120))
pet = Image.alpha_composite(pet, shade)
pd = ImageDraw.Draw(pet)
# blush
for bx in (cx-175, cx+175):
    pd.ellipse((bx-52, cy+38, bx+52, cy+102), fill=(220,125,96,48))
# eyes
for ex in (cx-112, cx+112):
    pd.ellipse((ex-34, cy-100, ex+34, cy+34), fill=(55,48,40,255))
    pd.ellipse((ex-14, cy-78, ex+4, cy-58), fill=(255,255,255,210))
# smile
pd.arc((cx-100, cy+38, cx+100, cy+180), start=20, end=160, fill=(55,48,40,255), width=17)
# small smile end dots
pd.ellipse((cx-8, cy+168, cx+8, cy+184), fill=(55,48,40,255))

img = Image.alpha_composite(img, pet)
img = img.resize((1024,1024), Image.LANCZOS)
img.save('Resources/icon-1024.png')

# iconset
os.makedirs('/tmp/ClaudeMonitor.iconset', exist_ok=True)
sizes = [(16,'16x16'),(32,'16x16@2x'),(32,'32x32'),(64,'32x32@2x'),(128,'128x128'),(256,'128x128@2x'),(256,'256x256'),(512,'256x256@2x'),(512,'512x512'),(1024,'512x512@2x')]
for px, name in sizes:
    img.resize((px,px), Image.LANCZOS).save(f'/tmp/ClaudeMonitor.iconset/icon_{name}.png')
print('icon written')
