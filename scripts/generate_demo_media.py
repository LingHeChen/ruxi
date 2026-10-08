"""Original procedural motion sample. No downloaded footage or third-party art."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'content/demo/media'
OUT.mkdir(parents=True,exist_ok=True)
FONT=os.environ.get('RUXI_VIDEO_FONT','/System/Library/Fonts/Supplemental/Songti.ttc')
CLIPS={
 'opening':('末班车的第七位乘客',50,['23:17。最后一班车，即将离站。','车厢名单上，只有六个名字。','一段来自未来的留言响起。','「请检查车上的异常装置。」','三个人，各自握着一段秘密。']),
 'role_investigator':('调查员 · 仅你可见',45,['你被派来核对末班车的记录。','有人删去了自己的痕迹。','监控和车厢名单，也许能回答你。','调查后，由你决定是否公开发现。']),
 'role_passenger':('乘客 · 仅你可见',45,['手机里，存着一段奇怪的留言。','留言提到一张旧车票。','你还不知道它意味着什么。','调查手机，再决定要信任谁。']),
 'role_conductor':('乘务员 · 仅你可见',45,['车门关闭前，你要确保一切正常。','控制柜一直处于锁定状态。','共享的记录和收到的道具，','也许能帮你解开设备的谜团。']),
 'interlude':('最后一声警报',45,['警报响起。探索的时间已经结束。','你们交换的信息，拼成了怎样的故事？','车门即将关闭。','离开、等待，还是公开异常？','这一次，由你们共同决定。']),
 'ending_E1':('真相',60,['你们公开了关键证据。','异常装置留下的记录，终于被看见。','那段未来留言，不再只是一个秘密。','三个角色的发现，拼成了这一次的真相。']),
 'ending_E2':('错过',60,['你们留在车厢里，继续等待。','第七位乘客，始终没有出现。','时间从指间流过。','也许那扇门，已经在别处关闭。']),
 'ending_E3':('余音',60,['你们走下了末班车。','车门合拢，远处的灯渐渐消失。','谁也没有再提起那段留言。','车厢里的声音，却还在。'])
}
manifest=[]
def vtt_time(seconds):return f'00:{int(seconds)//60:02d}:{int(seconds)%60:02d}.000'
for index,(code,(title,duration,lines)) in enumerate(CLIPS.items(),1):
    video=OUT/f'{code}.mp4'
    title_file=OUT/f'{code}.title.txt';title_file.write_text(title)
    filters=[
        'drawbox=x=58:y=108:w=364:h=416:color=0x829a98@0.22:t=2',
        'drawbox=x=104:y=166:w=272:h=316:color=0x829a98@0.16:t=2',
        'drawbox=x=146:y=216:w=188:h=238:color=0x829a98@0.10:t=2',
        'drawbox=x=50:y=80:w=380:h=2:color=0xf3ad47@0.35:t=fill',
        "drawtext=fontfile='%s':text='23  /  17':fontsize=18:fontcolor=0xb0b7bd:x=30:y=35"%FONT,
        "drawtext=fontfile='%s':textfile='%s':fontsize=26:fontcolor=0xf4f5f6:x=(w-text_w)/2:y=568"%(FONT,title_file),
        "drawtext=fontfile='%s':text='入戏 · 原创动效开发样片':fontsize=12:fontcolor=0x829a98:x=(w-text_w)/2:y=816"%FONT,
        "drawtext=fontfile='%s':text='—':fontsize=45:fontcolor=0xf3ad47@0.25:x=240+sin(t*0.25)*100:y=310"%FONT,
    ]
    subtitle=['WEBVTT','']
    span=duration/len(lines)
    for i,line in enumerate(lines):
        text_file=OUT/f'{code}.{i}.txt';text_file.write_text(line)
        start,end=i*span,(i+1)*span
        filters.append("drawtext=fontfile='%s':textfile='%s':fontsize=20:fontcolor=0xf4f5f6:x=(w-text_w)/2:y=658:enable='between(t,%s,%s)'"%(FONT,text_file,start,end))
        subtitle += [str(i+1),f'{vtt_time(start)} --> {vtt_time(end)}',line,'']
    vtt=OUT/f'{code}.vtt';vtt.write_text('\n'.join(subtitle))
    if not video.exists():
        subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i','color=c=0x142229:s=480x854:r=24',
            '-f','lavfi','-i','sine=frequency=110:sample_rate=44100','-t',str(duration),'-vf',','.join(filters),'-af','volume=0.02',
            '-c:v','libx264','-preset','veryfast','-crf','29','-pix_fmt','yuv420p','-c:a','aac','-b:a','48k','-movflags','+faststart',str(video)],check=True)
    manifest.append({'media_id':code,'asset_id':f'aaaaaaaa-aaaa-4aaa-8aaa-{index:012d}','file':video.name,'subtitle_file':vtt.name,'title':title,'duration_ms':duration*1000,'size_bytes':video.stat().st_size,'sha256':hashlib.sha256(video.read_bytes()).hexdigest(),'summary':'\n'.join(lines),'source':'Original procedural graphics and original narrative authored for Ruxi; synthesized low-volume tone. Not final filmed footage.'})
    print(f'{code}: ready ({video.stat().st_size} bytes)',flush=True)
(OUT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
for path in OUT.glob('*.txt'):path.unlink()
print('Eight original development clips ready.')
