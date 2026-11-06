#!/usr/bin/env python3
"""用离线原生控件素材编排演示；依赖 Pillow，不读取桌面。"""
from pathlib import Path
import argparse
from PIL import Image, ImageDraw, ImageFont, ImageSequence

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path, help='包含 native/ 导出素材的本地工作目录')
args = parser.parse_args()
base, native = args.directory, args.directory / 'native'
frames_dir = base / 'frames'
frames_dir.mkdir(parents=True, exist_ok=True)
W, H, FPS, SECONDS = 1280, 720, 6, 24
font_path = '/System/Library/Fonts/Hiragino Sans GB.ttc'
ink, muted, accent = '#173a34', '#526d65', '#087d6b'
def text(im, xy, value, size=24, color=ink):
    ImageDraw.Draw(im).text(xy, value, font=ImageFont.truetype(font_path, size), fill=color)
def contain(im, box, source):
    source = source.convert('RGB').copy()
    source.thumbnail((box[2], box[3]), Image.Resampling.LANCZOS)
    im.paste(source, (int(box[0]+(box[2]-source.width)/2), int(box[1]+(box[3]-source.height)/2)))
def card(im, box):
    x,y,w,h = box
    ImageDraw.Draw(im).rounded_rectangle((x,y,x+w,y+h), radius=14, fill='#ffffff', outline='#d3e1d9')
def fresh(number, title, description):
    im = Image.new('RGB', (W,H), '#f2f7f3')
    text(im, (38,20), 'Screenshot', 24)
    text(im, (1020,26), f'{number} / 04', 18, accent)
    text(im, (38,76), title, 38)
    text(im, (40,133), description, 20, muted)
    ImageDraw.Draw(im).line((38,665,1242,665), fill='#cfdfd5')
    text(im, (38,678), '原生控件 · 合成内容 · 脚本驱动 · 节奏已调整，非鼠标实录', 15, muted)
    text(im, (1065,678), 'kirktools / MIT', 15, muted)
    return im

gif_frames = [frame.convert('RGB').copy() for frame in ImageSequence.Iterator(Image.open(native/'recorded-sample.gif'))]
frames = []
for n in range(FPS*SECONDS):
    section, phase = divmod(n, FPS*6)
    index = min(23, int(phase/27*23))
    if section == 0:
        im = fresh('01', '文字，直接拖着改。', '角点缩放、手柄旋转；双击重编辑，精确参数仍然保留。')
        card(im, (38,188,1204,448))
        source = 'selection.png' if phase < 4 else f'text-{min(23,phase-4):02d}.png'
        contain(im, (55,200,1170,422), Image.open(native/source))
    elif section == 1:
        im = fresh('02', '固定栏，只出现一次。', '正文滚动并自动拼接：顶部导航与底部悬浮输入框保持独立。')
        card(im, (38,194,790,440)); contain(im, (50,206,766,416), Image.open(native/f'viewport-{index:02d}.png'))
        card(im, (870,194,372,440)); contain(im, (884,204,344,420), Image.open(native/f'scroll-{index:02d}.png'))
        text(im, (45,168), '合成页面：上下边缘固定，正文移动', 15, muted)
        text(im, (877,168), '真实会话的累计预览', 15, muted)
        text(im, (837,380), '→', 26, accent)
    elif section == 2:
        im = fresh('03', '同一个选区，录成 GIF。', '手动开始 / 停止，先预览，再保存；这里播放的是本次实际编码的动图。')
        card(im, (38,194,790,440))
        if phase >= 28:
            contain(im, (50,206,766,416), Image.open(native/'gif-preview.png'))
        else:
            contain(im, (50,206,766,416), gif_frames[min(len(gif_frames)-1, int(phase/27*(len(gif_frames)-1)))])
        card(im, (870,194,372,440))
        text(im, (896,230), '实际原生录制控件', 21, accent)
        contain(im, (880,285,352,190), Image.open(native/f'gif-controls-{index:02d}.png'))
        text(im, (896,505), '本机处理，无需账号', 19, muted)
        text(im, (896,548), '最长 60 秒 · 最高 10 fps', 17, muted)
    else:
        im = fresh('04', '钉在眼前，边看边做。', '贴图置顶，可移动、等比缩放；编辑工具栏也能拖开。')
        card(im, (38,194,1204,440))
        text(im, (65,223), '参考资料', 22, accent)
        for i, label in enumerate(['整理线索', '圈出重点', '把想法写下来']):
            ImageDraw.Draw(im).rounded_rectangle((65,280+i*94,480,350+i*94), radius=10, fill='#edf4ee')
            text(im, (84,297+i*94), label, 23, muted)
        # 窗口内容来自实际置顶窗口；排布仅用于呈现移动与缩放过程，不捕获桌面。
        progress = index/23
        contain(im, (520+int(progress*40),215,600-int(progress*40),385), Image.open(native/f'pin-{index:02d}.png'))
    frames.append(im)
    im.save(frames_dir/f'{n:04d}.png')
frames[22].save(base/'features-demo-poster.png')
small = [frame.resize((960,540), Image.Resampling.LANCZOS) for frame in frames]
sheet = Image.new('RGB', (960,540*8))
for i,n in enumerate([10,25,40,58,77,96,117,140]): sheet.paste(small[n],(0,540*i))
palette = sheet.quantize(colors=128)
converted = [frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in small]
converted[0].save(base/'features-demo.gif',save_all=True,append_images=converted[1:],duration=[170,160,170]*48,loop=0,optimize=True)
contact = Image.new('RGB',(1280,720*4))
for i,n in enumerate([22,58,96,140]): contact.paste(frames[n],(0,720*i))
contact.save(base/'contact-sheet.png')
print('已生成 24 秒新功能分镜、GIF 与封面；只使用离线导出的本应用视图。')
