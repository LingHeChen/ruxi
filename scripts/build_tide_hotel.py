"""Build the authored 1–4-player mystery. No AI runtime or remote dependency."""
import json
import hashlib
import re
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
out=ROOT/'content/c3/tide_hotel/story.json'
asset=lambda name:f"assets/stories/tide_hotel/{ {'lobby':'lobby-v2','lounge':'lounge-v2'}.get(name,name)}.png"
allof=lambda *args:{'op':'all','args':list(args)}
known=lambda ref:{'op':'has_knowledge','ref':ref}
flag=lambda ref,value=True:{'op':'eq','ref':f'world.{ref}','value':value}
setflag=lambda ref,value=True:{'op':'set','ref':f'world.{ref}','value':value}
reveal=lambda ref:{'op':'reveal','ref':ref,'audience':'self'}
s={ 'schema_version':4,'id':'tide_hotel','title':'潮汐旅馆：第九声钟响',
'rules':{'ap_per_round':6,'step_timeout_s':300,'proposal_ttl_s':60,'round_limit':24},
'roles':[{'id':'reporter','label':'徐闻 · 声音记者','location':'lobby','knowledge':[], 'goals':['查明江临失踪与第九声钟响的关系。','区分证词与实证，重建十五年前的救援时间线。','决定怎样保存证据，以及怎样让活着的人开口。']}],
'locations':[],'links':[],'objects':[],'clues':[],'actions':[],'templates':[],'events':[],
'initial':{'world':{'cabinet_open':False,'power':False,'manual_route':False,'decision':'','copied':False,'protected':False,'blackout_seen':False},'inventory':{'reporter':[]}},
'media':[],'votes':[], 'c3':{'profile_version':1,'suggested_content_version':4,'map_mode':'explore','passages':[],'interactions':[]},
'secrets':{'cabinet_code':{'answer':'0921','aliases':[]}},
'c3_settings':{'playtime_minutes':{'min':30,'max':60},'barriers':{'guest_door':'blocked'},'arrival_rules':{},'interaction_labels':{},'npcs':[],'objectives':[]}}
def media(id,text,image=None):
 s['media'].append({'id':id,'kind':'image' if image else 'text','uri':asset(image) if image else '', 'audience':'public','summary':text})
def clue(id,label,text,image):
 s['clues'].append({'id':id,'label':label,'text':text,'shareable':False})
 media('clue_'+id,text,image)
def obj(id,label,location,description,image):
 s['objects'].append({'id':id,'label':label,'location':location,'tags':[], 'description':description})
 media('item_'+id,description,image)
def action(id,label,loc,text,image,requires=(),effects=(),target=None,cost=1):
 cond=allof(*requires)
 s['actions'].append({'id':id,'label':label,'location':loc,'target':target,'cost':cost,'condition':cond,'display_condition':cond,'effects':list(effects)+[{'op':'cue','ref':'echo_'+id,'audience':'all','blocking':True}],'failure':[],'max_uses':1,'required_participants':1,'risk_text':'阅读与整理线索不消耗余力；本次调查推进一个行动。','threshold':None})
 media('echo_'+id,text,image)
def passage(a,b,gate=None,enter=None):
 d={'enabled':True,'cost':1,'discover_if':{'op':'always'},'enter_if':enter or {'op':'always'},'arrival_events':[]}
 s['c3']['passages'].append({'id':a+'_'+b,'a':a,'b':b,'barrier_id':gate,'ab':d,'ba':{'enabled':True,'cost':1,'discover_if':{'op':'always'},'enter_if':{'op':'always'},'arrival_events':[]}})
locations=[
('lobby','接待厅','雨从门缝里渗进来。黄铜铃上覆着一层盐霜，钥匙板的第九个挂钩空着。林素站在登记台后，灯照着她的双手，却照不到她的眼睛。你可以先问她江临的下落，也可以独自查看登记台。'),
('lounge','海景餐厅','摆钟的指针停在九点十七分。茶还留在杯底，麻将桌上却没有牌。这里能看见码头，窗玻璃把每一道闪电都复制成第二道。你记得自己进门时听到的九声钟响；一个停住的钟，为什么还会报时？'),
('corridor','二楼走廊','地毯已被搬走，湿脚印留在瓷砖上。清洁车停在209号房门外，轮下却是干的。尽头的应急灯每隔几秒暗一下。这里没有搏斗声，只有一扇门被反复开关后留下的轻响。'),
('room209','209号客房','打字机里夹着半页稿纸。窗开了三指宽，足够让雨进来，不足以让一个成年人离开。录音机摆在枕边，磁带还没有收回盒子。江临的鞋留在床下，行李箱里却少了一件防水外套。'),
('infirmary','护理室','陈雾把药柜擦得一尘不染。旧病历的封皮卷起，柜里有三瓶没有拆封的镇静药。她说自己只是来替旅馆老人换药，可她比任何人都熟悉这里的抽屉。'),
('generator','地下机房','机房的水只没过鞋底，供电柜已断开。赵朔用手电照着一根整齐断掉的控制线。工具箱里什么都没少。他看你的第一眼并不是防备，而是想确认你到底带没带录音设备。'),
('archive','阁楼资料室','灰尘把阁楼分成许多安静的层。旧客簿和港务记录被放在同一只铁柜里，柜门上是四位机械密码锁。靠窗有新近擦净的一块地板，那里曾放过一张椅子。'),
('boathouse','旧船屋','何泊坐在绞盘边。他的拐杖靠着一条新切断的绳索，潮水已经落到石阶下。他不急着说话，像在等一个十五年前就该问出的问题。这里连通后山避风小径，渡船不是离岛的唯一办法。')]
for id,label,desc in locations:
 s['locations'].append({'id':id,'label':label,'description':desc,'discovered':id=='lobby'})
 media('scene_'+id,desc,id)
passage('lobby','lounge');passage('lobby','corridor');passage('lobby','infirmary');passage('lobby','generator');passage('lounge','boathouse')
passage('corridor','room209','guest_door',{'op':'known','ref':'key'});passage('corridor','archive')
npcs=[('lin','林素','lobby','48岁，旅馆经营者。克制、礼貌，习惯替别人把话说完。你可以询问她的证词，也可以在掌握新证据后回访。','npc-lin'),('chen','陈雾','infirmary','34岁，护士。先问你的名字，再问你有没有得到当事人的同意。她愿意谈医学事实，对别的事很谨慎。','npc-chen'),('zhao','赵朔','generator','27岁，电工。赵世衡的儿子，长期住在岛外。今晚来修电，也想找出父亲留下的名字为什么从档案里消失。','npc-zhao'),('he','何泊','boathouse','67岁，退休渡船船长。说话很慢，对潮位和绳结比对人名更熟悉。他会明确告诉你哪些是亲眼看见，哪些只是猜测。','npc-he')]
for id,label,loc,desc,img in npcs:
 s['c3_settings']['npcs'].append({'id':id,'label':label,'location':loc,'description':desc,'schedule':[]})
 obj(id,label,loc,desc,img);media('portrait_'+id,desc,img)
obj('cabinet','旧港务铁柜','archive','柜内保存着2008年的原始救援记录。密码可从完整档案日期推导；不会猜也能在掌握登记簿后拆锁。','evidence-registry')
obj('switchboard','供电柜','generator','已隔离的供电控制柜。修复成功可得到一条额外时间记录；失败可手动读取封存表，不会堵住主线。','evidence-fuse')
obj('tape','江临的磁带','room209','江临留下的原始录音，证明钟声来自预录设备。','evidence-tape')
obj('record_copy','证据副本','archive','原始救援页、登记簿和江临录音的相互印证副本。','evidence-registry')
clues=[
('receipt','未退的房费','江临在23:05支付房费，收据后写着“采访结束后，从后山走”。没有退房记录。','evidence-key'),
('key','209钥匙','林素交出的209钥匙。她明确同意查看房间；不是偷取。','evidence-key'),
('clock','停钟与隐藏音箱','摆钟停在21:17，钟内没有上紧发条，却藏着音箱。第九声的尾音和前八声完全相同，是同一采样重复。停钟不是失踪发生时间。','evidence-clock'),
('footprints','脚印与轮痕','湿脚印从楼梯走向209；清洁车干轮痕覆盖脚印边缘。有人在雨停的短暂间隙推过车。脚印不是从窗外爬入。','evidence-footprints'),
('schedule','旅馆供电时间表','控制柜断电登记为22:55。摆钟21:17就已停。它们是两件不同的事。赵朔23:12收到报修短信，早于你23:40听见钟声。','evidence-fuse'),
('recording','预录的第九声','磁带试音段里，第九声后能听见江临说“如果我临时不在，不要用这声钟来给任何人定罪”。这是一段给采访对象的保护安排。','evidence-tape'),
('draft','未完成的采访稿','江临追查的是2008年9月21日的渡船事故。稿纸提出：落水者被送回岸上后，为何仍在海难名单里？它没有直接写谁杀了谁。','evidence-letter'),
('photo','缺角的旧合照','照片上有年轻的何泊、林素、丁远和赵世衡。丁远是林素的丈夫，2016年病逝。缺角来自折叠磨损，不是有人刮去第五张脸。','evidence-photo'),
('medical','先救回、后失联','原始护理页：2008年9月21日，赵世衡于22:10被送到船屋，意识清醒，可自己说姓名；22:35被一名港务人员带走。陈雾当年是随师实习，记录签字属于她的老师。','evidence-medical'),
('meds','药物不是失踪证据','江临取的是处理旧伤的抗生素，封口完整的镇静药没有减少。瓶子本身不能证明有人下药。','evidence-medical'),
('wire','人为切断的控制线','控制线有平整剪口，不是水浸故障。剪口高度适合站在门口操作，工具不是赵朔专用；何时剪断要与短信及电表共同判断。','evidence-fuse'),
('register','两份不同的名单','旅馆登记簿保留“赵世衡，救回岸上”的第一笔；送交港务的副本被改成“海上失联”。原件封存日期：9月21日，柜门便条写“按月日”。','evidence-registry'),
('rescue','迟到的救援命令','港务原始页：22:10救回、22:35带离、23:05丁远命令暂停搜寻。备注提到船屋后间上锁。事故发生后人仍活着，后续拘留与延误需单独调查。','evidence-registry'),
('letter','林素没有寄出的信','未寄信里，林素写自己改了救援副本，以保护丈夫丁远。她知道赵世衡曾活着上岸。信承认掩盖，没有承认今晚杀害江临。','evidence-letter'),
('rope','最近切断的船绳','绳索是为拖出淤沙中的小艇才切开，残留纤维仍卡在绞盘。它不是绑人的绳索。船屋后墙的小门通往避风小径。','evidence-rope'),
('witness','江临走的是后山','何泊亲眼看到江临23:25披防水外套走向后山，左腿跛但能行走。何泊帮他取了外套，没有看见他到达山上。证词证明离开方式，不能单独证明此刻安全。','npc-he'),
('contact','安全确认','避风站有线电话接通。江临本人核对你与他约定的采访口令，说明他在护林员处；同意提交录音与档案副本，要求不要公开护士的个人病历。','cg-dawn'),
('lin_first','林素的第一份证词','林素说23:20送热水时江临仍在房中，23:40听见钟声才发现他不在。她隐瞒22:55曾去机房，也把送热水时间提前了。','npc-lin'),
('lin_confess','林素承认掩盖','面对护理页、名单与未寄信，林素承认2008年改名单；今晚剪电是想让江临停止播放旧录音。她在22:55离开机房，与报修日志相符。她愿意把原始材料交出，但要求先确认江临安全。','npc-lin'),
('chen_first','陈雾的第一份证词','陈雾22:40给江临处理旧伤，23:15接到他提出的告别电话。她没有进209房间。她要求先区分真实药物记录和关于“下药”的想象。','npc-chen'),
('zhao_first','赵朔的第一份证词','赵朔23:12收到报修短信，23:18进入地下机房；林素说自己从没去过机房。赵朔的父亲赵世衡在2008年事故中“失联”，官方解释一直没有改变。','npc-zhao'),
('he_first','何泊的第一份证词','何泊说今晚潮位不允许大船离港，但后山小径可行。他不愿说替谁拿了外套，希望先看江临是否留了同意披露行踪的说明。','npc-he'),
('reconstruction','两条时间线','今晚：21:17停钟，22:40处理旧伤，22:55人为断电，23:12报修，23:25江临走后山，23:40预录钟响。旧案：22:10赵世衡活着上岸，22:35被带走，23:05救援暂停。今晚的失踪是避险，旧案的掩盖是真实存在。','cg-confrontation')]
for args in clues:clue(*args)
media('opening','''你叫徐闻，给一家地方电台做声音纪录。今晚，你带着录音笔来到潮汐旅馆，赴作家江临的约。他在邀请信里只写了一句：“如果钟声响到第九下，请别相信第一个解释。”
渡船在你到岛后停航。你进门时，海景餐厅传来九声缓慢的钟响。接待台的林素说，江临不见了。她伸手去关录音笔，你却发现她的手在抖。
这不是限时逃生。你可以随时回看线索，逐个询问在场的人，按自己的节奏查证。天气推进采用调查回合，不等于现实分钟；阅读对话时不会扣行动点。开场先问林素，再检查钟，能得到第一组相互矛盾的时间。
你这次要找的也许不只是一个失踪的人。十五年前，有一个已经回到岸上的名字，被重新写回了海里。''','lobby')
action('read_receipt','查看江临的收据','lobby','''收据压在黄铜铃下面，纸边浸了水，中心却是干的。林素没有阻止你拿起来，只提醒不要把原件带走。金额、签名和23:05的时间都很清楚。背面那行“采访结束后，从后山走”用铅笔写得很轻。
你翻到登记台背面，挂钩编号到九，209的钥匙却不在。江临交过房费，却没有退房；这可能意味着匆忙离开，也可能只是计划晚些回来。你把“没有退房”写成事实，把“被迫离开”留在问号下面。
录音笔还在工作。远处的雨声比刚才小，你能听见林素用指甲轻敲桌面。这个动作没有证据价值，但你记住了它：接下来要询问的，不只是她知道什么，还有她为什么担心你正在记录。''','evidence-key',effects=[reveal('receipt')])
action('talk_lin','问林素：最后见到江临是什么时候？','lobby','''“十一点二十分，我给他送热水。”林素答得很快，“他还说，明早要早一点起来。”你问房间里有没有别人，她摇头，又补了一句“至少我没看见”。这次她给自己留了余地。
她说九声钟响后才察觉209的灯灭了。你抬头看钥匙板：“你用备用钥匙进去了？”她把一把钥匙放到台上，说自己只开门看了一眼，床边没有人，窗户开着。
你明确问是否同意你查看房间。她迟疑后点头：“你别动他的稿子。也别让那个电工觉得这又和他父亲有关。”你没有问过电工的父亲。林素意识到说多了，转身把另一壶水倒进水槽。
钥匙现在在你手边。209可以进入；她的时间只是第一份证词，还需要钟、机房和在场者的记录来核对。''','npc-lin',effects=[reveal('lin_first'),reveal('key')],target='lin')
action('ask_lin_family','问林素：为什么提到电工的父亲？','lobby','''“岛上都知道赵世衡。”林素说，“十五年前那场风暴，他没回来。”她指向楼梯边的旧合照，那里有人用照片修过的木框遮住了一角。你没有碰木框，只请她说出每个人的名字。
她逐个念：何泊、她自己、丈夫丁远、赵世衡。提到丁远时她停了一下，说他已经去世七年。你问，丁远是船员吗？“港务值班。”她回答。一个发出救援指令的人，与一个执行指令的人，并不是同一种责任。
“江临查这个，赵朔也查这个。”她说，“但他们不是一起上岛的。”你看着那张缺角照片，提醒自己不要把破损直接当作毁证。纸边的折痕连续，角上没有新鲜剪口。
你记下照片能证明的关系：四个人曾一起站在船屋前。至于谁在事故夜做了什么，还在照片之外。''','evidence-photo',requires=[known('lin_first')],effects=[reveal('photo')],target='lin')
action('inspect_clock','检查停钟与第九声','lounge','''摆钟停在九点十七分。你轻轻拨开玻璃门，钟摆没有移动。发条松着，击锤旁的细线也没有接上。这样的钟不可能在十一点四十分完整敲九下。
你在钟底找到一个掌心大的音箱，它被布套包着，只露出电源指示灯。把录音笔贴近，你回放自己进门时收下的钟声。前八声之间有微小间隔，第九声的尾部却与第八声逐点重叠；是同一段声音复制，不是钟的机械余音。
你没有立刻拆走音箱，因为那会改变现场。先拍照、标注位置、录下设备状态。钟面停在21:17，是钟本身的时间；扬声器在23:40播放，是另一条时间线。
林素的“钟响才发现人不见”仍可能成立。但任何人都不能用这第九声，证明江临在那一刻还在房里。''','evidence-clock',effects=[reveal('clock')])
action('listen_window','听窗边的海与楼上的脚步','lounge','''你把录音笔从钟边移到窗台，窗外的海很响，楼上却更安静。偶尔有轮子碾过瓷砖，随后是一声很短的门锁响。客房走廊没有地毯，脚步应该比轮声更明显。
你推开一条窗缝，海风带来柴油味，眼前的码头没有亮灯。无论江临是自愿离开还是被迫离开，现在都不能简单说他“坐船走了”。何泊在旧船屋里，那是你能询问潮位的人。
窗台上有一只杯子，杯底剩下冷茶。你没有凭气味猜药物，只记下杯子位置。若要判断身体状况，应去问真正处理过伤口的人，而不是把每一个陌生气味都写成毒。
这一刻没有得到决定性证据，却得到了一种调查顺序：先查能复核的声音、通路与记录，再讨论谁有动机。''','lounge',requires=[known('clock')])
action('inspect_tracks','检查209门外的脚印','corridor','''脚印从楼梯方向过来，在209门前转身。鞋底花纹很常见，机房、船屋和旅馆储物柜里都可能有类似雨靴。你量了长度，没有把它直接对应到任何一个人。
清洁车的左轮从脚印边缘压过，干燥的轮痕盖住一部分湿印。推车发生在脚印之后，而且轮子当时没有带水。这让“从窗外翻入再推走”的想象失去了支撑；窗台狭窄，地上也没有从窗边延伸出的滴水线。
你在走廊尽头看见通往阁楼的折梯，灰尘里留下被椅脚压过的浅痕。门并没有锁，锁着的是里面的铁柜。
这些细节只说明行动顺序。一个人可以在离开前换鞋，也可以托别人推车。你需要房内的录音与衣物，来确认江临有没有提前准备。''','evidence-footprints',effects=[reveal('footprints')])
action('inspect_luggage','查看衣物与半页稿纸','room209','''行李箱里整齐叠着两件衬衫，少了能够挡雨的外套。窗台很窄，没有鞋印；床下那双鞋干着，鞋尖朝里，是脱下来摆放的样子。你没有发现明显搏斗痕迹。这不能证明没有发生争执，却削弱了“突然被人从窗户带走”的说法。
打字机里夹着的稿纸以问句结束：赵世衡被救回岸上后，又去了哪里？下面有一行日期，2008年9月21日。江临不是在写鬼故事，他在追查一段救援记录被改写的经过。
稿纸旁有今天的便签：“原件、护理页、名单，三份互证。”这给了你三个可验证的方向。你把稿纸放回滚轴原位，拍下完整页，再拍纸张边缘；不把半句话当成完整结论。
江临留下了调查方法，也留下了明显的离开准备。现在要确定谁帮助过他，以及帮助发生在什么时间。''','evidence-letter',effects=[reveal('draft')])
action('play_tape','播放江临留下的原始录音','room209','''第一段是海风，第二段是试音。江临的声音很近：“不必把我的名字播出去，只要材料还在。”接着传来几声钟响，其中一声被他反复重放，最后拼成九声。
录音里另一人问：“你这样走，他们会找你。”江临答：“那就让他们先找证据。告别电话我会打，后山有人接我。要是我临时不在，不要用这声钟给任何人定罪。”录音结束前，有纸张被装进防水袋的声音。
你无法单凭这一段确认另一人的身份，也无法确认计划完全实现。但它解释了钟声：江临有意安排一个引人注意的时点，让资料不会在他离开后悄悄消失。
你得到的是原始磁带，连同设备位置拍照保存。下一步应向陈雾核对告别电话，向何泊核对后山路。失踪可能是避险，不等于旅馆没有别的事需要解释。''','evidence-tape',effects=[reveal('recording'),{'op':'grant','ref':'tape'}])
action('talk_chen','问陈雾：江临需要什么治疗？','infirmary','''陈雾先问你，采访材料会交给谁。你说，在确认事实之前不会播出任何名字。她才把药柜钥匙收进衣袋，告诉你江临左腿有旧伤，今晚22:40来换药。
“他能自己走，不需要人扶。”她说，“我给了抗生素，没有给镇静药。”你问为什么桌上有空瓶，她把瓶底转给你看：那是早已洗净用来装消毒水的瓶子，不能凭外形认定内容。
她23:15接到江临的电话，对方只说要离开一会儿，并请她不要把私人病历交给旅馆。陈雾记得电话里没有风声，像在室内。
你问她是否愿意展示药品领用记录。她同意你核对与今晚有关的数量，但不允许翻看其他人的病历。你接受这个边界：有关案件的事实可以查证，无关病人的隐私不应成为调查代价。''','npc-chen',effects=[reveal('chen_first')],target='chen')
action('inspect_medicine','核对药物与领用记录','infirmary','''三瓶镇静药的封口都完整，瓶号与上午库存一致。抗生素少了一盒，领用签名是江临。你看见他签字的笔迹和稿纸便签一致；这只是辅助核对，不把笔迹鉴定当作自己已经完成的事。
陈雾说：“我知道别人想听到的故事。雨夜、空瓶、一个护士，合起来就像下药。但那不是记录。”你把结论写得很窄：现有库存不支持镇静药被领走，江临取用的是治疗旧伤的药。
她指着抽屉里一本旧护理册，犹豫了很久，没有立刻拿给你。“里面还有一个人的名字。要是你确实在查2008年那天，我们可以只看对应的一页。”
今晚的误导被拆掉一层，旧案的入口却露了出来。你需要用江临的采访稿说明查阅理由，不能把整本护理册当作可随意公开的战利品。''','evidence-medical',requires=[known('chen_first')],effects=[reveal('meds')])
action('ask_chen_oldcase','出示采访稿，核对旧护理页','infirmary','''陈雾读完稿纸照片，把护理册打开到2008年9月21日。她当年随老师在岛上实习，字还写得很挤。第一条记录是22:10：“赵世衡，男，意识清醒，自报姓名。低温，右肩擦伤。”
你问能否误认。她摇头，但没有说绝不可能：“老师问了两遍名字，他都回答了。何船长也认得他。”第二条是22:35，被一名港务人员带走。没有死亡记录，没有再次落水记录。
“后来正式名单写海上失联。我说过这页不同，老师让我留好原册。”陈雾的声音很低，“老师已经去世。我能证明的，是当时记录了什么。”
你只复制对应页，遮住其他病人的姓名。这个名字从海里回到岸上，再从官方材料里消失了。现在可以拿护理页去与旅馆名单、何泊的救援记忆互证；今晚是否有人失踪，与旧案是否有人被掩盖，必须分别回答。''','npc-chen',requires=[known('draft'),known('chen_first')],effects=[reveal('medical')],target='chen')
action('ask_chen_call','核对23:15的告别电话','infirmary','''你播放江临录音中的“告别电话”。陈雾没有因此放松，反而拿出手写值班记：“我怕以后说不清，所以记了时间。”23:15，江临说走后山，到了避风站会再联系。
她没有接到第二通电话。手机信号随后断了，无法知道是他失约，还是电话没能打通。“你别把这个空白写成死亡。”她说，“也别把他早有计划写成此刻绝对安全。”
护理室墙上仍挂着一部有线电话，通向旧船屋和山上的避风站。旅馆客房的交换机停电了，这条应急线是独立的。
你记下线路位置，准备请何泊核对端口。你能做的不是凭一句话给江临宣布安全，而是尝试真正接通他，并得到他对材料公开范围的明确意见。''','npc-chen',requires=[known('recording'),known('chen_first')],target='chen')
action('talk_zhao','问赵朔：几点收到报修？','generator','''赵朔把手机放在关闭的供电柜上。23:12，林素发来短信：“机房进水，帮我看看。”他23:18到这里，电早已断了。你问，他看见谁离开吗？“没有。我只看到门没关严。”
他指着控制线，声音突然提高：“这不是水泡坏的。”你没有急着认同他的全部判断，请他先解释剪口与正常故障的区别。他拿来一段废线作比较，平整断面与烧熔断面确实不同。
说到父亲，他把手电握得很紧。“他们说他在海上失联。我每年拿同一张名单去问，得到的都是同一句话。”你告诉他，目前还没有核对旧记录，不会把他的愤怒当作犯罪证据，也不会把他的愿望当作事实。
他退开一步，让出控制柜。报修短信给今晚多了一个时间锚点；林素关于机房的说法，需要在取得电表记录后重新询问。''','npc-zhao',effects=[reveal('zhao_first')],target='zhao')
action('inspect_wire','检查剪口与断电日志','generator','''供电柜已经隔离，你只查看断线与外部记录，不接触带电部分。陶瓷保险丝完整，主开关没有过载痕迹。控制线的剪口高度在门口就能够到，不需要熟悉柜内线路的人钻进去。
机械记录卡显示22:55断电。赵朔的短信是23:12，晚十七分钟。摆钟却更早停在21:17。三个时间不能混成一个“停电时所有事情同时发生”的瞬间。
赵朔承认，岛上不少人都有能剪线的钳子，他自己的工具也没有唯一性。“我可以说不是自然故障，但不能说是谁。”你把这句话完整录下。
要读取交换机上最后一条维修日志，可以尝试恢复隔离后的控制电源。也可以放弃修复，拆下封存的纸质计时卡。后者更费力，但不会因为一次运气不好就让证据永远消失。''','evidence-fuse',requires=[known('zhao_first')],effects=[reveal('wire'),reveal('schedule')])
action('manual_log','手动读取封存计时卡','generator','''你选择不再碰供电。赵朔拿出维护手册，按编号找到纸质计时卡的封口。封口上有上月港务巡检的骑缝章，打开前你先拍照，把拆封经过录下来。
卡上22:55的记录与柜外一致。附页注明，客房交换机依赖旅馆供电，应急站有线电话独立供电。因此，停电可以让客房电话失效，却不能解释避风站电话是否接通。
这条路线比直接修复多花了一些时间，但同样得到完整信息。你没有理由因为骰子不站在自己这边，就放弃一个能通过公开操作取得的事实。
赵朔把计时卡重新装入透明袋。他问，你会回来告诉他旧案的结果吗？你答应把已经核实的部分当面说明，也会明确标出仍需调查的部分。''','evidence-fuse',requires=[known('wire')],effects=[setflag('manual_route'),reveal('schedule')],cost=2)
action('tell_zhao_medical','告诉赵朔：父亲曾活着上岸','generator','''你先说“这是一份当年的护理记录”，没有先说“你父亲一定被杀了”。赵朔逐字读到“意识清醒，自报姓名”时，坐在工具箱上，很久没有开口。
“那他们这些年让我找的，不是同一件事。”他终于说。你解释，事故与上岸后的带离应分别调查，护理页说明他活着回来，不说明后来全部经过。
赵朔想立即冲去问林素。你请他等原始救援页与名单互证，再一起谈。他问，等待是不是又一种拖延。你告诉他区别：这一次原件位置有人记录，副本有人保存，问题也不会被换成一句模糊的“风浪太大”。
他没有原谅任何人，只答应暂时留下。你知道，给予一个人可靠的事实，比给他一个痛快但未经核实的凶手名字更难，也更必要。''','npc-zhao',requires=[known('medical'),known('zhao_first')],target='zhao')
action('read_register','对照两份客人名单','archive','''阁楼外侧的客簿不用密码就能翻阅。2008年的原册上，赵世衡后面有“救回岸上”四个字，墨色与当页相近。送交港务的复写副本却写“海上失联”，两者不是同一措辞。
你把页码、日期和装订线都拍下。修改发生在副本上，不能仅凭这一点认定原册全部真实；但它足以让“从未回岸”的官方叙述受到质疑。
铁柜便条写“封存日，按月日”。原册封存日期为9月21日，机械锁需要四位数字。你把0921记在调查页边，准备输入。若锁因错误尝试卡住，可依据已经找到的维护说明拆开锁舌；不会让整桩旧案依赖猜谜。
柜里可能有发出命令的人留下的原始页。护理记录证明被救回的状态，客簿证明两套名单的差别，最后还要核对带离与暂停救援发生在哪个环节。''','evidence-registry',effects=[reveal('register')])
action('bypass_cabinet','依据维护页拆开卡住的锁舌','archive','''你不再猜密码，按客簿夹着的维护页找到铁柜侧面的检修孔。这里只需要拆下两颗生锈螺钉，取出锁舌，并不会破坏文件本身。你记录拆锁经过，把零件放在同一只托盘里。
林素没有阻止，她在楼下说过可以查看旧材料。这不是悄悄撬走一个人的私人财物；你仍然需要清楚记录取得资料的方式，让后来的人能够检查。
柜门开了，里面没有传说中的遗骨，也没有一封替所有人定罪的绝笔。只有纸页、印章、被折过许多次的命令单。
真正改变调查的通常不是打开柜门的动作，而是柜门后面的内容能否与已有事实相互印证。你已经得到继续查证的机会。''','evidence-registry',requires=[known('register'),flag('cabinet_open',False)],effects=[setflag('cabinet_open')],cost=2)
action('read_rescue','读取原始救援命令','archive','''第一张是调度原始页，22:10救回，22:35由港务人员带离，23:05暂停搜寻。签发人是丁远。附注里写“船屋后间上锁，待问话”，不是正常救援记录会出现的措辞。
你把这页与护理记录并排。陈雾记录的是当事人身体状态，调度页记录的是带离与命令；不同来源在22:10与22:35两个节点对上了。客簿副本却把这一段全部抹掉。
最后一行墨水晕开，关于天亮后进入后间的记录只剩半句。你不替它补出自己最想看到的结论。能明确说的，是救回的人在之后被扣留，救援被人为暂停，失联叙述掩盖了这些过程。
这需要正式调查保存原件、查清死亡原因与责任，不能让一段广播代替裁决。但它已经足够要求所有相关者停止把名字推回风浪里。''','evidence-registry',requires=[flag('cabinet_open')],effects=[reveal('rescue')])
action('read_unsent_letter','读取林素没有寄出的信','archive','''信没有收件地址，开头写“如果有一天孩子们还要问”。林素写自己把“救回岸上”改成“海上失联”，因为丁远说赵世衡要揭发他挪用救援款，他们的旅馆也会保不住。
她写过一句“我以为只是一晚”，又把“一晚”划掉，改成“等风停”。没有任何一行能够替死者解释后来的空白，也没有一行把全部责任交给天气。
信的末尾提到江临来问同样的问题，她担心赵朔见到原件，会知道她早就知道。纸上没有今晚杀人的承认。你必须把掩盖旧案与今晚失踪分开，否则最容易传播的故事会再次覆盖真正发生的事。
你把信放回信封，记录封存位置。回接待厅时，拿护理页、名单和信一起询问，比单独举着一封情绪强烈的信指控，更能让对方无法继续用模糊回答躲开。''','evidence-letter',requires=[flag('cabinet_open')],effects=[reveal('letter')])
action('copy_evidence','保存三份证据的互证副本','archive','''你按时间顺序拍下护理页、客簿原件与救援命令，把页码与封存位置说进录音笔。磁带不做剪辑，另存完整副本。这样，任何一句被引用的话都能回到原始上下文。
你在副本首页写上两个限制：病历中的无关姓名遮蔽；纸页真实性与具体责任应由正式调查复核。你不会因为想给赵朔一个交代，就略去这两条。
江临提醒的“三份互证”现在完整了。即使某一份原件之后发生损坏，护理状态、名单变化与救援命令之间的关系仍有记录可查。
你把副本放进防水袋。窗外雨势正在减弱，但调查还没有结束：江临是否安全，需要真正确认；林素是否愿意当面说明，需要给她一个不靠误指控也无法逃避事实的问题。''','evidence-registry',requires=[known('medical'),known('register'),known('rescue'),known('recording')],effects=[setflag('copied'),{'op':'grant','ref':'record_copy'}])
action('talk_he','问何泊：今晚有什么离岛方式？','boathouse','''“大船走不了。”何泊把拐杖伸向石阶，指出刚退去的潮线。“不过上山可以。后墙有小门，绕过旧水井，能到避风站。”你问江临是否知道这条路，他把目光移到门边的挂钩。
挂钩上少了一件防水外套。何泊说，只要有人留下希望公开行踪的说明，他愿意讲自己见到的部分。他不想让一个离开的人，因为被说成“逃跑”就失去继续讲事实的机会。
你注意到绞盘边的绳索断面很新。何泊让你看另一头，仍卡在轮齿里。他说今晚拖小艇离开淤沙时切掉了损坏的一段，绳索没有绑过人。
你可以核对切绳痕迹，也可以在拿到江临录音后再问他的离开时间。一个证人拒绝立刻满足你的猜测，不等于他没有愿意配合的边界。''','npc-he',effects=[reveal('he_first')],target='he')
action('inspect_rope','检查绳索与后山小门','boathouse','''绳索的另一端还嵌在绞盘齿里，轮轴周围有新刮出的木屑。断口没有反复摩擦留下的毛边，损坏段被整齐切掉。小艇船底的淤泥，与石阶下面的滩泥一致。
何泊指向后墙的小门。门闩从内侧抬起，外面的脚步一直延伸到上山路口。你只能看见这一段，不能透过雾看见一个人最后是否安全抵达。
你把地图上后山避风站的位置记下来。那里有独立应急电话，与护理室相连；不需要客房交换机恢复，也不需要等渡船重新出航。
绳索原本看上去像一个容易引人联想的证物，检查后它却指向正常的救援准备。你删除笔记里的“绑缚？”两字，换成“切断用途已与绞盘痕迹相符”。承认一条怀疑被证据排除，也是一种进展。''','evidence-rope',requires=[known('he_first')],effects=[reveal('rope')])
action('ask_he_departure','出示录音，核对江临的离开','boathouse','''江临录音里的声音响起，何泊闭上眼听完，没有要求删去哪一段。他说，自己23:25取了防水外套给江临，对方从后门走向山路，左腿跛，但没有人扶或押着他。
“我亲眼看见他到旧水井。再往上，雾挡住了。”何泊把这两句分开，说得很清楚。你感谢他没有把“见到出发”说成“保证安全”。
你问是谁建议录九声钟。何泊说，江临自己决定的，希望你即使见不到他，也会留下查资料。他只帮忙拿外套，没有操作录音设备。
今晚的顺序开始连起来：房间里有离开准备，录音里有安排，证人看见自愿走向后山。但最后一环仍缺失。船屋墙上的应急电话能直接呼叫避风站，你可以现在尝试接通，不用把所有希望放到明早的船上。''','npc-he',requires=[known('recording'),known('he_first')],effects=[reveal('witness')],target='he')
action('ask_he_rescue','拿护理页询问当年的救援','boathouse','''何泊盯着“22:10”很久，然后用拐杖尖在地上划了一条线。“这里是岸。人已经回来，就不该再被写成还在海上。”他说自己把赵世衡送到护理床时，确实听见他报了名字。
22:35，一个穿港务外套的人带赵世衡去后间。何泊当时准备第二趟搜救，23:05收到丁远暂停命令。他知道后间上了锁，却选择先服从命令。后来他每次讲事故，都只讲风浪，省去了这段。
“我能说命令是谁发的，也能说我没有去开那扇门。”他看着你，“别替我写成尽力救了所有人。”你没有安慰他，说出愧疚不等于责任已经结束。
护理页与调度页得到第三个来源的支持。何泊愿意在副本上注明哪些是亲见、哪些是后来听说。他不能给你完整的死因，却可以让之后的调查从一条不被天气掩盖的时间线开始。''','npc-he',requires=[known('medical'),known('rescue'),known('he_first')],target='he')
action('call_station','接通避风站，确认江临安全','boathouse','''电话有短暂的杂音，随后一个男人问：“潮退了吗？”你没有仅凭声音认人，按约定问江临邀请信背面的采访口令。对方答出“把名字留在岸上”，又准确说出你们上一封信讨论过的章节。
江临在护林员处。今晚与林素争执后，他担心材料被夺走，按计划经后山离开。他明确说，没有人把他从窗户带走，也没有人给他镇静药。那第九声钟，是他提前设置的提醒。
“不是为了给谁设罪。”他说，“是怕我暂时说不了话，你们就只剩一个方便的解释。”他同意提交完整录音与资料副本，不同意公开无关病历。
你请护林员接电话确认站点和通话登记，对方给出应急记录编号。现在可以把“计划离开”推进到“已与本人及站点核对安全”。江临会在天亮后配合调查；旧案不会因为今晚没有发生谋杀，就自动变成无事发生。''','cg-dawn',requires=[known('witness'),known('rope')],effects=[reveal('contact'),setflag('protected')])
action('confront_lin','拿三份材料回访林素','lobby','''你把护理页、两份名单与未寄信按顺序摆在台上。没有先问“是不是你杀的”，而是问：“你何时知道赵世衡活着上了岸？副本为什么变了？”林素第一次没有替问题换一个说法。
她承认，2008年亲手改了副本，以保护丁远和旅馆。她不知道自己这样做能让多少后续问题再也没有人问。今晚22:55，她去机房剪控制线，想让江临停止播放旧采访录音；后来又发短信叫赵朔来修，假装只是水浸。
你指出两件事可以同时成立：她参与掩盖与人为断电；江临随后自愿离开，钟声来自预录。不能用旧案的责任直接替代对今晚的查证。
林素拿出另一只文件袋，愿意交出材料。她问赵朔会不会原谅她。你说那不是你能替别人做的决定。你能要求的，是她完整说明自己的行为，不再把名字、时点或问题改写成更好听的故事。''','npc-lin',requires=[known('medical'),known('register'),known('letter'),known('wire')],effects=[reveal('lin_confess')],target='lin')
action('reconstruct','把两条时间线放到桌上','lounge','''你把今夜与2008年分成两列。21:17只是机械钟停住；22:55人为断电；23:12报修；23:25江临走向后山；23:40预录钟声播放。不存在一声钟同时证明所有人的到场和离场。
另一列是赵世衡：22:10活着上岸，22:35被带离，23:05救援暂停，名单随后被修改。护理页、旅馆原册与港务原始命令在不同环节互相支持。
四个人围着桌子。陈雾坚持保留记录原貌，赵朔要让父亲的名字重新进入调查，何泊愿意说明服从命令的部分，林素必须说明掩盖与剪电。谁都没有得到一句足以替自己结束责任的简单评价。
江临已安全确认，证据副本已保存。你现在可以作最后选择：把完整材料交给正式调查并播出不涉及隐私的核实报道，先做有时限的封存交接，或者仍追求一个更容易传播的“今夜谋杀”故事。最后一种选择会违背你手中的事实。''','cg-confrontation',requires=[known('clock'),known('schedule'),known('recording'),known('medical'),known('rescue'),known('lin_confess'),known('contact'),flag('copied')],effects=[reveal('reconstruction')])
for id,label,decision,text in [
('publish_truth','提交原件，播出核实后的调查','truth','你逐项列出已经核实与仍待查清的事实，请四名证人分别确认自己的记录。完整材料进入正式调查，播出的版本遮蔽无关病历。你没有承诺一个裁决，只承诺不会再把岸上的名字写回海里。'),
('seal_handover','先封存交接，约定七日内核实跟进','sealed','你决定先完成证据封存与证人交接，七日内公开已经核实的进度。赵朔不同意无限期等待，你把期限与联系人写进交接单。暂缓播出不是撤回调查，也不能成为新的沉默。'),
('accuse_murder','把林素直接指为今夜的杀人者','false','你把旧案的掩盖与今晚的失踪合成了一条痛快的指控。陈雾把应急通话登记放到你面前，江临的声音仍在电话另一头。这个结论比事实更响，却与已经查证的安全确认直接矛盾。')]:
 action(id,label,'lounge',text,'cg-confrontation',requires=[known('reconstruction'),flag('decision','')],effects=[setflag('decision',decision)])
action('leave_early','停止追查，等待天亮离岛','lobby','''你告诉林素自己决定停止调查。她没有阻止，把渡船恢复通知压在登记台上。你仍保留已经取得的笔记，但没有完成最后的互证与交接。
这不是一个被强迫的选择。你也可以暂时合上录音笔、继续回看线索，再作决定；但一旦确认离岛，这个夜晚会在还没有问完的问题中结束。那些材料不会自动因为你离开而变成答案。
远处又有金属轻响，这次只是风吹动门口的铃。你知道至少有一件事是真的：声音本身，不会替任何一个人把经过讲清楚。''','lobby',effects=[setflag('decision','leave')])
endings={
 'truth':('shore_names','名字留在岸上','''天亮后，江临从避风站下来，亲自确认录音与稿纸。赵朔把父亲的名字写在证据目录第一行；陈雾留下限定范围的证词；何泊与林素分别说明自己做过与没做过的事。
你提交原始材料，报道只使用已经交叉核实的部分。它没有标题党式的“雨夜凶手”，也没有替正式调查宣布死因。它指出，一个活着上岸的人被带离、救援暂停，随后记录被改写；这些事实需要回应。
潮汐旅馆暂时关闭。赵朔没有说原谅，林素也不能把一句道歉当作结案。你们约定继续追踪调查，保存原件，让每一个空白仍以空白的形式留在记录里。
九声钟没有找到一个今晚的杀人者，却让一个旧案重新有了不能被轻易改写的起点。你的录音最后是海浪，以及渡船靠岸时真实的一声钟。'''),
 'sealed':('seven_days','七日之约','''材料装进封存袋，原件目录和副本交接分别由证人签字。你暂不播出未经复核的责任判断，但公开说明调查已启动，并约定七日内跟进。
江临同意等待核实，赵朔坚持每一页都要有去向。你把联系方式与期限交给他，也留下完整录音。没有人被要求先原谅，才有资格要求答案。
这是一个谨慎的结局，也是一项尚未结束的承诺。只要进度有记录、期限有人检查，暂缓并不等于遗忘；若你不再回来，这个选择就会变成又一次沉默。'''),
 'false':('loud_error','最响的错误','''江临安全抵达的记录推翻了你的今夜谋杀指控。旧案材料仍然重要，却因为一条未经区分的报道承受了本可避免的质疑。
赵朔问，你明明拿到了护理页、报修日志与通话登记，为什么还要选择一个已经被证据排除的解释。你无法用“想尽快给交代”回答这件事。
录音里第九声钟的尾音一遍遍重放。你终于意识到，重复得最响的部分，并不因此更真实。你必须更正报道，保存原件，重新取得证人的信任。'''),
 'leave':('unanswered','尚未问完的雨夜','''渡船恢复了，旅馆重新把钥匙挂上板。你带走未完成的笔记，未能把今晚的行踪与十五年前的记录完整拼合。
没有新的证据证明那些最初的怀疑。你可以回看已经获得的内容，也可以重新开始这段故事，选择留下多问一个能够被复核的问题。
海上的雾渐渐散去。有些人离开不是消失，有些人被写成失联，却曾真实站回岸上。这个夜晚，还欠他们一个完整的记录。''')}
for decision,(id,label,text) in endings.items():
 media(id,label+'\n\n'+text,'cg-dawn' if decision in ('truth','sealed') else 'cg-confrontation')
 s['events'].append({'id':'end_'+decision,'trigger':'step_end','priority':100,'once':True,'condition':flag('decision',decision),'effects':[{'op':'end','value':id}]})
media('storm_passed','调查暂时中止\n\n天亮的渡船已抵达。你用完了这个夜晚的调查轮次。已经取得的记录仍保存在手记中，但未完成的核对不能自动填成结论。你可以重新开始，先询问林素、查停钟、听江临的录音，再让旧案的三个来源互相印证。','cg-dawn')
s['events'].append({'id':'fallback','trigger':'round_end','priority':1,'once':True,'condition':{'op':'gte','ref':'clock.round','value':24},'effects':[{'op':'end','value':'storm_passed'}]})
media('blackout','''楼下灯灭了一瞬，应急红灯随即亮起。有人在接待台说“又来了”，却没有解释“又”指的是哪一次。
这次变化没有摧毁证据，也没有让任何NPC凭空消失。已知的机房与应急电话仍可调查。你记下眼前的停电现象，不把它自动倒推为过去所有灯灭的原因。''','cg-blackout')
s['events'].append({'id':'blackout_at_four','trigger':'round_end','priority':50,'once':True,'condition':{'op':'eq','ref':'clock.round','value':4},'effects':[{'op':'cue','ref':'blackout','audience':'all','blocking':True}]})
s['c3']['interactions']=[
{'id':'cabinet_password','target_id':'cabinet','kind':'password','cost':1,'attempts':{'scope':'actor','max':6,'reset_event':None},'on_success':[{'op':'set_flag','ref':'cabinet_open','value':True}],'on_failure':[],'audience':'actor','format':'pin','normalization':'exact','min_length':4,'max_length':4,'answer_secret_ref':'cabinet_code'},
{'id':'repair_switchboard','target_id':'switchboard','kind':'check','cost':1,'attempts':{'scope':'actor','max':1,'reset_event':None},'on_success':[{'op':'set_flag','ref':'power','value':True}],'on_failure':[],'audience':'actor','base_target':70,'modifiers':[],'formula':'1d100_lte'}]
s['c3_settings']['interaction_labels']={'cabinet_password':{'label':'输入铁柜密码','risk_text':'按封存日的月日输入四位数字。错误扣1余力；六次后仍可按维护页拆锁，不会堵住主线。'},'repair_switchboard':{'label':'尝试修复隔离后的控制电源','risk_text':'成功率70%；无论结果如何，均可手动读取封存计时卡。不会损坏证据。'}}
s['c3_settings']['objectives']=[{'id':'find_jiang','label':'确认江临此刻安全','layer':'personal','role_ids':['reporter'],'condition':flag('protected'),'latch':True,'membership_policy':'follow_current'},{'id':'keep_records','label':'保存旧案互证副本','layer':'personal','role_ids':['reporter'],'condition':flag('copied'),'latch':True,'membership_policy':'follow_current'}]
# Conditional interaction results have distinct narrative and images, not bare AP messages.
for id,ref,img,text in [('cabinet_success','cabinet_open','evidence-registry','机械锁舌退回，柜门缓缓打开。密码只是取得资料的方式；真正需要核对的内容，还在柜里。你可以读取原始救援命令与未寄出的信。'),('power_success','power','evidence-fuse','隔离后的控制电源恢复，维修时间表再次可读。记录与纸质计时卡一致：22:55断电，23:12报修。故障修复提供核对便利，不改变已有事实。')]:
 media(id,text,img)
 s['events'].append({'id':id,'trigger':'action_end','priority':30,'once':True,'condition':flag(ref),'effects':[{'op':'cue','ref':id,'audience':'all','blocking':True}]})
for a in s['actions']:
 if a['id'] in ('publish_truth','seal_handover','accuse_murder','leave_early'): a['risk_text']='确认将结束本次故事；返回可继续调查。'+a['label']+'。'
# Flexible attendance: every selected role can investigate the complete case.
role_specs=[('reporter','徐闻 · 声音记者','你带来江临的采访邀请。你的录音笔收下了九声钟响；声音相似不等于时间相同。','evidence-tape'),('archivist','沈砚 · 地方档案研究员','你正整理2008年的海难目录，发现港务副本没有注明原始记录的保存地点。先寻找原件，再比较副本。','evidence-registry'),('volunteer','许澄 · 救援志愿者','你在避风站协助值守，知道后山仍有一条通往避风站的步行小径。交通中断不代表所有离岛方式都消失。','evidence-rope'),('photographer','陆遥 · 纪实摄影师','你为江临的采访拍摄现场。照片应保留位置、拍摄时刻与原始文件；不凭一张破损照片推定毁证。','evidence-photo')]
s['roles']=[]
s['initial']['inventory']={}
for rid,label,brief,img in role_specs:
 cid='brief_'+rid
 clue(cid,label+' · 私人行前笔记',brief,img)
 s['clues'][-1]['shareable']=True
 s['roles'].append({'id':rid,'label':label,'location':'lobby','knowledge':[cid],'goals':['确认江临安全，核对今晚与旧案的两条时间线。','与同伴交换调查发现，保存证据并共同决定交接方式。']})
 s['initial']['inventory'][rid]=[]
s['c3_settings']['min_players']=1
s['c3_settings']['coalesce_actions']=True
s['c3_settings']['team_decisions']=['publish_truth','seal_handover','accuse_murder','leave_early']
for a in s['actions']:
 if a['id'] in s['c3_settings']['team_decisions']:
  a['risk_text']='单人确认即可结束；多人需要全员在同一地点选择同一方案。一人提交不会单方面结束故事。'+a['label']+'。'
for c in s['clues']: c['shareable']=True
# Main evidence is recorded in the team notebook; private briefs are opt-in shares.
for a in s['actions']:
 marker='done_'+a['id']
 s['initial']['world'][marker]=False
 a['condition']=allof(a['condition'],flag(marker,False))
 a['display_condition']=a['condition']
 a['effects'].append(setflag(marker))
 for e in a['effects']:
  if e['op']=='reveal': e['audience']='all'
for o in s['c3_settings']['objectives']:
 o['layer']='public';o['role_ids']=[]
opening=next(m for m in s['media'] if m['id']=='opening')
opening['summary']=opening['summary'].replace('你叫徐闻，给一家地方电台做声音纪录。今晚，你带着录音笔来到潮汐旅馆，赴作家江临的约。','你们因各自的调查来到潮汐旅馆，赴作家江临的约。声音记者、档案研究员、救援志愿者和纪实摄影师，可由1～4人自由选择任意角色；独自到访也能完成全部调查。').replace('开场先问林素','先回看自己的行前笔记；多人可以分头探索，主线发现会同步到团队手记，私人笔记可自行分享。每个调查步等待同伴提交行动或结束回合；所有人在场并阅读完叙事后再继续。结局选择需要全员回到同一地点，选择同一个方案；意见不同时不会擅自结束故事。开场先问林素')
media('cover','1～4人悬疑 · 预计30–60分钟 · 四名NPC · 八个场景 · 五个结局','cover')
# Author-controlled emphasis. Gold marks anchors, jade marks evidence; no verdict is highlighted.
def emphasize(text):
 for name in ['江临','林素','陈雾','赵朔','何泊','赵世衡']:
  text=text.replace(name,'**'+name+'**',1)
 for evidence in ['原始救援记录','原始护理页','旅馆登记簿','港务原始页','预录钟声','护理页、客簿原件与救援命令','原始磁带','两条时间线']:
  text=text.replace(evidence,'=='+evidence+'==',1)
 return text
for m in s['media']:
 m['summary']=emphasize(m['summary'])
for l in s['locations']: l['description']=emphasize(l['description'])
for c in s['clues']: c['text']=emphasize(c['text'])
for n in s['c3_settings']['npcs']: n['description']=emphasize(n['description'])
manifest={f'assets/stories/tide_hotel/{file.name}':hashlib.sha256(file.read_bytes()).hexdigest() for file in (ROOT/'apps/mobile/assets/stories/tide_hotel').glob('*.png')}
for m in s['media']:
 if m['kind']=='image':
  file=ROOT/'apps/mobile'/m['uri']
  if file.is_file():
   m['sha256']=hashlib.sha256(file.read_bytes()).hexdigest();manifest[m['uri']]=m['sha256']
(ROOT/'services/core/priv/c3/bundled_art.json').write_text(json.dumps(manifest,indent=2)+'\n')
out.write_text(json.dumps(s,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'story':str(out),'actions':len(s['actions']),'clues':len(s['clues']),'media':len(s['media']),'npcs':len(npcs),'narrative_characters':sum(len(re.sub(r'\*\*|==','',m['summary'])) for m in s['media'] if m['id'].startswith('echo_') or m['id']=='opening')},ensure_ascii=False))
