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
'communication':{'voice':{'enabled':True,'scope':'scene'}},
'rules':{'ap_per_round':6,'step_timeout_s':300,'proposal_ttl_s':60,'round_limit':24},
'roles':[{'id':'reporter','label':'徐闻 · 声音记者','location':'lobby','knowledge':[], 'goals':['查明江临失踪与第九声钟响的关系。','区分证词与实证，重建十五年前的救援时间线。','决定怎样保存证据，以及怎样让活着的人开口。']}],
'locations':[],'links':[],'objects':[],'clues':[],'actions':[],'templates':[],'events':[],
'initial':{'world':{'cabinet_open':False,'power':False,'manual_route':False,'decision':'','copied':False,'protected':False,'blackout_seen':False,'guest_room_access':False},'inventory':{'reporter':[]}},
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
('lobby','接待厅','雨从门缝里渗进来。黄铜铃上覆着一层盐霜，钥匙板的第九个挂钩空着。林素在登记台后整理收据，听见门响才抬起脸。'),
('lounge','海景餐厅','摆钟的指针停在九点十七分。茶还留在杯底，麻将桌上却没有牌。闪电照亮窗外空着的码头。你记得自己进门时听到的九声钟响；一个停住的钟，为什么还会报时？'),
('corridor','二楼走廊','地毯已被搬走，湿脚印留在瓷砖上。清洁车停在209号房门外，轮下却是干的。尽头的应急灯每隔几秒暗一下。楼下有人放下杯子，声音沿着楼梯传上来。'),
('room209','209号客房','打字机里夹着半页稿纸。窗开了三指宽，足够让雨进来，不足以让一个成年人离开。录音机摆在枕边，磁带还没有收回盒子。江临的鞋留在床下，行李箱里却少了一件防水外套。'),
('infirmary','护理室','陈雾把药柜擦得一尘不染。旧病历的封皮卷起，柜里有三瓶没有拆封的镇静药。她说自己只是来替旅馆老人换药，可她比任何人都熟悉这里的抽屉。'),
('generator','地下机房','机房的水只没过鞋底，供电柜已断开。赵朔用手电照着一根整齐断掉的控制线。工具箱里什么都没少。他看了看你手里的录音笔，将手电转向断线。'),
('archive','阁楼资料室','阁楼里积着灰，窗下的地板有一块擦净的方印。旧客簿摞在铁柜旁，柜门上装着四位机械密码锁，门缝里夹着一角泛黄的纸。'),
('boathouse','旧船屋','何泊坐在绞盘边。他的拐杖靠着一条新切断的绳索，潮水已经落到石阶下。他听见脚步声，把拐杖挪到身边。后墙有一扇小门，门缝里吹进带着草木气味的风。')]
for id,label,desc in locations:
 s['locations'].append({'id':id,'label':label,'description':desc,'discovered':id=='lobby'})
 media('scene_'+id,desc,id)
passage('lobby','lounge');passage('lobby','corridor');passage('lobby','infirmary');passage('lobby','generator');passage('lounge','boathouse')
passage('corridor','room209','guest_door',{'op':'eq','ref':'world.guest_room_access','value':True});passage('corridor','archive')
npcs=[('lin','林素','lobby','48岁，旅馆经营者。客人还没开口，她往往就已递来热水。今晚水壶烧开了几次，她一杯也没喝。','npc-lin'),('chen','陈雾','infirmary','34岁，护士。袖口挽得齐整，药柜钥匙一直放在衣袋里。提起江临，她先看了一眼你手里的录音笔。','npc-chen'),('zhao','赵朔','generator','27岁，电工。赵世衡的儿子，长期住在岛外。今晚来修电，也想找出父亲留下的名字为什么从档案里消失。','npc-zhao'),('he','何泊','boathouse','67岁，退休渡船船长。拐杖柄磨出了深色的光。说话慢，提到旧船和潮水时，偶尔会抬手比画。','npc-he')]
for id,label,loc,desc,img in npcs:
 s['c3_settings']['npcs'].append({'id':id,'label':label,'location':loc,'description':desc,'schedule':[]})
 obj(id,label,loc,desc,img);media('portrait_'+id,desc,img)
obj('cabinet','旧港务铁柜','archive','铁柜门上贴着“封存日，按月日”的便条。四只数字轮已经磨亮，柜侧有一个带螺钉的检修盖。','evidence-registry')
obj('switchboard','供电柜','generator','供电控制柜已经隔离，控制线断口平整。柜旁挂着维护手册和封存的纸质计时卡。','evidence-fuse')
obj('tape','江临的磁带','room209','江临留下的原始录音，证明钟声来自预录设备。','evidence-tape')
obj('record_copy','证据副本','archive','原始救援页、登记簿和江临录音的相互印证副本。','evidence-registry')
obj('lin_documents','林素交出的文件袋','lobby','林素亲手交出的剩余档案原件。文件袋封口已打开，保留了她补交材料的出处。','evidence-registry')
obj('key','209钥匙','lobby','林素交出的209钥匙。她明确同意查看房间；不是偷取。','evidence-key')
clues=[
('receipt','未退的房费','江临在23:05支付房费，收据后写着“采访结束后，从后山走”。没有退房记录。','evidence-key'),
('clock','停钟与隐藏音箱','摆钟停在21:17，钟内没有上紧发条，却藏着音箱。第九声的尾音和前八声完全相同，是同一采样重复。钟面时间与23:40听见的钟声不一致。','evidence-clock'),
('footprints','脚印与轮痕','湿脚印从楼梯走向209；清洁车干轮痕覆盖脚印边缘。有人在雨停的短暂间隙推过车。窗边没有延伸进房间的滴水线。','evidence-footprints'),
('schedule','旅馆供电时间表','控制柜断电登记为22:55。摆钟21:17就已停。两项记录相差一小时三十八分钟。赵朔23:12收到报修短信，早于你23:40听见钟声。','evidence-fuse'),
('recording','预录的第九声','磁带试音段里，第九声后能听见江临说“如果我临时不在，不要用这声钟来给任何人定罪”。磁带里还录下了他准备离开的谈话。','evidence-tape'),
('draft','未完成的采访稿','江临追查的是2008年9月21日的渡船事故。稿纸提出：落水者被送回岸上后，为何仍在海难名单里？末句停在一个问号上。','evidence-letter'),
('photo','缺角的旧合照','照片上有年轻的何泊、林素、丁远和赵世衡。丁远是林素的丈夫，2016年病逝。照片缺角处纸边发白，折痕连续。','evidence-photo'),
('medical','先救回、后失联','原始护理页：2008年9月21日，赵世衡于22:10被送到船屋，意识清醒，可自己说姓名；22:35被一名港务人员带走。陈雾当年是随师实习，记录签字属于她的老师。','evidence-medical'),
('meds','药品领用记录','江临取的是处理旧伤的抗生素，封口完整的镇静药没有减少。桌上空瓶的标签写着“消毒水”。','evidence-medical'),
('wire','人为切断的控制线','控制线的剪口平整，站在门口就能够到。岛上常见的钳子都能剪断这根线。记录卡显示22:55断电，赵朔23:12才收到报修短信。','evidence-fuse'),
('register','两份不同的名单','旅馆登记簿保留“赵世衡，救回岸上”的第一笔；送交港务的副本被改成“海上失联”。原件封存日期：9月21日，柜门便条写“按月日”。','evidence-registry'),
('rescue','迟到的救援命令','港务原始页：22:10救回、22:35带离、23:05丁远命令暂停搜寻。备注提到船屋后间上锁。附注写着“船屋后间上锁，待问话”，末尾关于天亮后的记录已经洇坏。','evidence-registry'),
('letter','林素没有寄出的信','未寄信里，林素写自己改了救援副本，以保护丈夫丁远。她知道赵世衡曾活着上岸。末尾提到江临又来问起这件事。','evidence-letter'),
('rope','最近切断的船绳','绳索是为拖出淤沙中的小艇才切开，残留纤维仍卡在绞盘。被割下的损坏段还扔在墙边。船屋后墙的小门通往避风小径。','evidence-rope'),
('witness','江临走的是后山','何泊亲眼看到江临23:25披防水外套走向后山，左腿跛但能行走。何泊帮他取了外套，没有看见他到达山上。从旧水井往上的路被雾挡住了。','npc-he'),
('contact','安全确认','避风站有线电话接通。江临本人核对你与他约定的采访口令，说明他在护林员处；同意提交录音与档案副本，要求不要公开护士的个人病历。','cg-dawn'),
('lin_first','林素的第一份证词','林素说23:20送热水时江临仍在房中，23:40听见钟声才发现他不在。她隐瞒22:55曾去机房，也把送热水时间提前了。','npc-lin'),
('lin_confess','林素承认掩盖','面对护理页、名单与未寄信，林素承认2008年改名单；今晚剪电是想让江临停止播放旧录音。她在22:55离开机房，与报修日志相符。她愿意把原始材料交出，但要求先确认江临安全。','npc-lin'),
('chen_first','陈雾的第一份证词','陈雾22:40给江临处理旧伤，23:15接到他提出的告别电话。她没有进209房间。药品领用册仍保存在护理室。','npc-chen'),
('zhao_first','赵朔的第一份证词','赵朔23:12收到报修短信，23:18进入地下机房；林素说自己从没去过机房。赵朔的父亲赵世衡在2008年事故中“失联”，官方解释一直没有改变。','npc-zhao'),
('he_first','何泊的第一份证词','何泊说今晚潮位不允许大船离港，但后山小径可行。他看着空衣钩，说江临托他办过事，要先听听江临留下的话。','npc-he'),
('reconstruction','两条时间线','今晚：21:17停钟，22:40处理旧伤，22:55人为断电，23:12报修，23:25江临走后山，23:40预录钟响。旧案：22:10赵世衡活着上岸，22:35被带走，23:05救援暂停。今晚的失踪是避险，旧案的掩盖是真实存在。','cg-confrontation')]
for args in clues:clue(*args)
media('opening','''第一幕 · 第九声钟响\n\n23:40，潮汐旅馆。
雨横着打过门廊，海景餐厅里传来钟声。一下，又一下，第九下响过后，接待厅重新静下来。
柜台上放着江临留的信封，封面写着：“如果钟声响到第九下，请别相信第一个解释。”
林素从楼梯口下来，手里攥着209的钥匙。
“江临不在房里。”
她把钥匙收进掌心，望了一眼门外。渡船已经停航，码头的灯在雨里灭了。''','lobby')
action('read_receipt','查看江临的收据','lobby','''黄铜铃下面压着一张收据，纸边被雨水洇湿了。林素见你伸手，按住纸角：“看可以，别拿走。”
签名是江临，付款时间23:05。背面有一行很淡的铅笔字：采访结束后，从后山走。
你把收据翻回来。房费已经付过，退房一栏却空着。林素的指甲在桌面上敲了两下，见录音笔还亮着，又把手收回柜台下面。''','evidence-key',effects=[reveal('receipt')])
action('talk_lin','问林素：最后见到江临是什么时候？','lobby','''“十一点二十，我给他送过热水。他说明早要早起。”林素答得很快。
“房里还有别人吗？”
“没有。”她顿了顿，“我没看见。”
她说，钟响以后才发现209的灯灭了。你看了一眼钥匙板，她便从口袋里摸出钥匙，搁在台上：“我开门看过，床边没人，窗倒是开着。”
你问能不能上去看看。她点头，手仍搭在钥匙上。
“别弄乱他的稿子。还有，别让那个电工以为又跟他父亲有关。”
你还没提过电工。她松开钥匙，转身将壶里的热水倒进水槽。''','npc-lin',effects=[reveal('lin_first'),{'op':'grant','ref':'key'},setflag('guest_room_access')],target='lin')
action('ask_lin_family','问林素：为什么提到电工的父亲？','lobby','''“赵世衡。岛上的老人都认得。”林素望着楼梯边的合照，“十五年前出事那晚，他没回来。”
你请她认一认照片上的人。她依次点过去：何泊，她自己，丁远，赵世衡。
“丁远是我丈夫，走了七年了。”
“他也跑船？”
“港务值班。”她将歪掉的相框扶正，“江临来问过，赵朔也来问。他们不是一起来的。”
木框遮住了照片缺掉的一角。露出的纸边磨得发白，折痕一直延伸到背面。四个人站在船屋前，赵世衡的手还搭在丁远肩上。''','evidence-photo',requires=[known('lin_first')],effects=[reveal('photo')],target='lin')
action('inspect_clock','检查停钟与第九声','lounge','''钟面停在21:17。你打开玻璃门，拨了拨钟摆；它晃两下就停了，发条已经松到底，击锤旁的细线也断着。
钟底塞着一个小音箱，外面裹了布，指示灯从布缝里透出来。
你回放进门时录下的声音。第八声末尾有一小段沙响，第九声也有，连长短都一样。把两段来回听了几遍，你找到了同一处杂音。
23:40响起的九声钟，来自这个音箱。你拍下它的位置，没有挪动。隔着餐厅的门，还能听见林素在接待台收拾杯子。''','evidence-clock',effects=[reveal('clock')])
action('listen_window','听窗边的海与楼上的脚步','lounge','''窗外浪声很大。你把录音笔移到窗台，楼上传来轮子碾过瓷砖的声音，接着是门锁轻轻一响。
推开窗缝，海风夹着柴油味灌进来。码头上一片黑，系泊的船随浪起伏，没有一条正在出港。
窗台留着半杯冷茶。你记下杯子的位置，朝旧船屋望去；那边还有灯，何泊的身影映在窗上。若有人知道今晚能不能走船，应该就是他。''','lounge',requires=[known('clock')])
action('inspect_tracks','检查209门外的脚印','corridor','''湿脚印从楼梯口一路到209，在门前转了个向。鞋底是常见的雨靴纹路。
清洁车左轮压过一枚脚印，轮痕已经干了，脚印边缘还湿着。你蹲下来拍照，再看向门槛：水迹从楼梯来，没有通向窗边。
走廊尽头通往阁楼的折梯放着，门虚掩。你探头看了一眼，里面堆着旧册子，靠墙有一只上锁的铁柜。''','evidence-footprints',effects=[reveal('footprints')])
action('inspect_luggage','查看衣物与半页稿纸','room209','''床下摆着一双干鞋，鞋尖朝里。行李箱摊在椅子上，两件衬衫叠得整齐，外套的位置空着。窗只开了三指宽，窗台积着雨水，没有鞋印。
打字机里夹着半页稿纸，最后一句没有写完：赵世衡被救回岸上后，又去了哪里？
下方标着日期——2008年9月21日。
旁边的便签写着：“原件、护理页、名单，三份互证。”纸夹里另有邀请信的副本，背面记着采访口令：“把名字留在岸上。”你拍下稿纸和便签。箱子侧袋里还留着一只空衣架，衣架上的防水外套不在了。''','evidence-letter',effects=[reveal('draft')])
action('play_tape','播放江临留下的原始录音','room209','''磁带转起来，先是海风，然后有人试了两下话筒。
江临的声音传出来：“不必把我的名字播出去，只要材料还在。”几声钟响过后，他倒带，将其中一声反复放了几遍，拼成九声。
另一个人问：“你这么一走，他们会找你。”
“那就让他们找。告别电话我会打，后山有人接我。”江临停了一会儿，“我临时不在，也别拿这声钟给谁定罪。”
最后是一阵纸张摩擦声，像有人把东西装进袋子。你取下磁带，在盒上记好原来的位置。录音中的另一个声音听不清，江临说的后山，也还没去过。''','evidence-tape',effects=[reveal('recording'),{'op':'grant','ref':'tape'}])
action('talk_chen','问陈雾：江临需要什么治疗？','infirmary','''陈雾没有立刻回答，先问：“这些话，你打算给谁听？”
你说是来找江临的。她看了看录音笔，收起药柜钥匙。
“十点四十来换的药，左腿旧伤。他自己走进来，也自己走出去。我给了抗生素。”
你问起桌上的空瓶。她将瓶底转过来，标签下面还贴着一条手写纸：“消毒水。旧瓶洗干净装的。”
23:15，江临给她打过电话，说要离开一会儿，嘱咐她别把病历交给旅馆。
“领药记录可以看他的那一行。”陈雾将册子压在手下，“别的病人，跟这件事没关系。”''','npc-chen',effects=[reveal('chen_first')],target='chen')
action('inspect_medicine','核对药物与领用记录','infirmary','''三瓶镇静药都没拆封，瓶号与上午的库存记录一一对得上。抗生素少了一盒，江临在领用栏签了名。
“外面是不是已经有人说我给他下药了？”陈雾问。
你把记录还给她。她没有追问，拉开抽屉，里面躺着一本卷边的旧护理册。
“江临也来翻过这个。”她手指停在封皮上，“查的是2008年那场事故。你要是带着他的稿子，就拿来给我看看。”''','evidence-medical',requires=[known('chen_first')],effects=[reveal('meds')])
action('ask_chen_oldcase','出示采访稿，核对旧护理页','infirmary','''陈雾读完稿纸照片，翻开护理册。2008年9月21日那页，字写得密密麻麻，签名在页脚。
“那时我跟着老师实习。这页是他签的。”
22:10：赵世衡，男，意识清醒，自报姓名。低温，右肩擦伤。
22:35：由港务人员带离。
“名字会不会记错？”
“老师问了两遍。他都答了。何船长就在旁边，也认得他。”她往后翻了一页，又翻回来，“后来名单说他在海上失联。我拿给老师看，他让我把原册留好。”
她用白纸盖住旁边几位病人的名字，让你拍下这两行。纸移开时，页脚的签名已经褪成浅褐色。''','npc-chen',requires=[known('draft'),known('chen_first')],effects=[reveal('medical')],target='chen')
action('ask_chen_call','核对23:15的告别电话','infirmary','''听到录音中的“告别电话”，陈雾从口袋里拿出值班记事本。
23:15那行写着：江临，走后山，到避风站后再联系。
“第二通没打来。”她说，“后来手机也没信号了。”
你问有没有别的办法。她指向墙上的有线电话：“这条线接船屋和山上的避风站，单独供电。客房电话断了，它还能用。何船长知道怎么接。”
她把记事本合上，又问了一遍：“找到了，给我回个话。”''','npc-chen',requires=[known('recording'),known('chen_first')],target='chen')
action('talk_zhao','问赵朔：几点收到报修？','generator','''赵朔擦掉手机屏上的水，把短信递过来。
23:12，林素：“机房进水，帮我看看。”
“我十八分到的。那时已经没电了，门也没关严。”
他用手电照着断线：“水能泡出这种口子？”从工具箱里抽出一段烧坏的废线，放在旁边。一个断口平整，一个焦黑卷曲。
你问起赵世衡，他握紧了手电。
“我爸。他们说人没回来。”他将短信划走，屏幕上是一张旧名单的照片，“每年问，每年就让我看这个。”
赵朔让开柜门：“你先看。林素说她没下过机房，我可没说过。”''','npc-zhao',effects=[reveal('zhao_first')],target='zhao')
action('inspect_wire','检查剪口与断电日志','generator','''赵朔确认控制柜已经隔离，才让你靠近。保险丝完好，开关没有烧痕，断线的剪口在门口伸手就能够到。
柜外机械记录卡停在22:55。你拿它与23:12的短信对照，中间隔了十七分钟。餐厅的钟则早在21:17就停了。
“有钳子就能剪，我那把也行。”赵朔说，“你问谁干的，我没看见。”
最后一条维修日志存在控制设备里。赵朔翻开手册，指给你看：可以尝试恢复隔离后的控制电源，也可以拆封旁边的纸质计时卡。''','evidence-fuse',requires=[known('zhao_first')],effects=[reveal('wire'),reveal('schedule')])
action('manual_log','手动读取封存计时卡','generator','''你请赵朔取出纸质计时卡。他按维护手册找到封口，上面还盖着上个月的巡检骑缝章。你拍下封口，他才下刀划开。
卡上同样记着22:55断电。附页画着两条线路：客房交换机接旅馆供电，避风站应急电话单独供电。
赵朔将卡装进透明袋，递到你手里。
“旧案那边查出什么，能不能告诉我？”
你答应了。他低头收拾螺钉，一颗一颗放回工具盒。''','evidence-fuse',requires=[known('wire')],effects=[setflag('manual_route'),reveal('schedule')],cost=2)
action('tell_zhao_medical','告诉赵朔：父亲曾活着上岸','generator','''赵朔接过护理页的照片，看到“意识清醒，自报姓名”，在工具箱上坐了下来。
“他回来了？”
你指给他看22:10那一行。他把照片放大，又缩回去。
“我这些年，一直在问船沉在哪儿。”
读到22:35，他忽然站起来：“谁带走的？”
这页只写了港务人员，没有姓名。你告诉他，阁楼还有名单和救援记录。
他朝门外走了两步，停住：“行，先找。找齐了我跟你一起去问她。”照片仍亮在他手里，他没有把屏幕关掉。''','npc-zhao',requires=[known('medical'),known('zhao_first')],target='zhao')
action('read_register','对照两份客人名单','archive','''铁柜外摞着旧客簿。2008年的原册里，赵世衡名字后写着“救回岸上”；夹在里面的港务复写副本，同一个位置却是“海上失联”。
你将两页并排拍下，连页码和装订线一起收进画面。
柜门贴着便条：“封存日，按月日。”原册封存日期是9月21日。你看向四位机械锁，记下0921。
客簿后面还夹着一张维护页，画了锁舌和侧面的检修孔。即使锁转不动，也能从那里拆开。''','evidence-registry',effects=[reveal('register')])
action('bypass_cabinet','依据维护页拆开卡住的锁舌','archive','''维护页标出的检修孔藏在柜侧。你卸下两颗生锈的螺钉，把锁舌慢慢抽出来，零件放进旁边的托盘。
柜门往外一沉，开了。纸张受潮的气味扑出来，最上面是一叠调度单，红印章已经透到背页。
你拍下拆开的锁和文件原来的排列，再把手伸向第一张命令单。''','evidence-registry',requires=[known('register'),flag('cabinet_open',False)],effects=[setflag('cabinet_open')],cost=2)
action('read_rescue','读取原始救援命令','archive','''调度原始页写着三条记录：22:10救回，22:35由港务人员带离，23:05暂停搜寻。最后一条的签发人是丁远。
旁边另有小字：“船屋后间上锁，待问话。”
22:10和22:35，与护理页记下的时间相同。你将两份照片放在一起，客簿副本里的“海上失联”就在旁边。
纸页末尾被水洇过。关于天亮后进入后间的记录，只剩半句，后面辨不出字。你换了几个角度拍照，仍没能读出余下的内容。''','evidence-registry',requires=[flag('cabinet_open')],effects=[reveal('rescue')])
action('read_unsent_letter','读取林素没有寄出的信','archive','''信封上没有地址，信的开头是：“如果有一天孩子们还要问……”
林素写，丁远告诉她，赵世衡要揭发他挪用救援款。事情闹开，旅馆也保不住。她于是将副本上的“救回岸上”改成了“海上失联”。
“我以为只是一晚。”这句里的“一晚”被划掉，改作“等风停”。
末尾提到江临。他又来问同样的事，她怕赵朔看到原件。
你读到最后，信没有署日期，也没有寄出。护理页、两份名单和这封信，如今都能摆到林素面前了。''','evidence-letter',requires=[flag('cabinet_open')],effects=[reveal('letter')])
action('copy_evidence','保存三份证据的互证副本','archive','''你把护理页、客簿原件和救援命令按时间摆好，逐页拍摄，将页码和原件的位置念进录音笔。磁带也另存了一份完整副本。
病历旁边无关的姓名用纸遮住，洇坏的字保留原样。目录上，22:35之后仍有一段空白。
副本装进防水袋，袋口扣紧。窗外雨小了些。还要回接待厅问林素，也得设法联系上江临。''','evidence-registry',requires=[known('medical'),known('register'),known('rescue'),known('recording')],effects=[setflag('copied'),{'op':'grant','ref':'record_copy'}])
action('talk_he','问何泊：今晚有什么离岛方式？','boathouse','''“渡船出不了港。”何泊拿拐杖点了点石阶上的潮线，“上山倒能走。后门出去，绕旧水井，到避风站。”
“江临知道这条路吗？”
他望向门边空着的衣钩，没有回答。
“他托我办过事。你要有他留下的话，拿来，我再跟你讲。”
绞盘边搭着一根新断的绳子。见你看它，何泊将另一头从轮齿里拽出来。
“拖小艇时坏的，割掉了。你自己看看，另一头还在这儿。”''','npc-he',effects=[reveal('he_first')],target='he')
action('inspect_rope','检查绳索与后山小门','boathouse','''断绳的一端仍卡在绞盘里。轮轴旁散着新木屑，小艇船底糊着与石阶下一样的滩泥。被切掉的损坏段扔在墙边，长度刚好对得上。
何泊抬起后墙小门的门闩。外面有脚印，沿着泥路走到上山路口，往后就看不清了。
他指着雾里：“避风站在上面。有线电话能通，船屋这部就能打。跟护理室接的是同一条应急线。”''','evidence-rope',requires=[known('he_first')],effects=[reveal('rope')])
action('ask_he_departure','出示录音，核对江临的离开','boathouse','''何泊听完江临的录音，伸手关小了音量。
“十一点二十五。我把外套拿给他，他从这里出去。”他指向后门，“左腿不太好，走得慢，没让人扶。”
“你看见他走到哪儿？”
“旧水井。再往上都是雾。”
他把空衣钩拨正：“钟是他自己的主意。怕你们来了找不着人，就掉头回去。我只管给他拿衣服，那机器我不会弄。”
墙上的电话蒙着一层灰。何泊拿袖子擦了擦听筒：“要问到没到，打上去吧。”''','npc-he',requires=[known('recording'),known('he_first')],effects=[reveal('witness')],target='he')
action('ask_he_rescue','拿护理页询问当年的救援','boathouse','''何泊将护理页拿到灯下，手指停在22:10。
“是我送回来的。他冷得牙齿打架，问名字还能答。”
22:35，穿港务外套的人把赵世衡带去了后间。何泊忙着准备第二趟搜救，直到23:05，丁远下令停船。
“后间锁了。我知道。”他把纸放低，“我想着先把船上的事做完。后来……我没去开门。”
绞盘发出一声轻响，他伸手按住。
“这些年别人问，我都说那晚风大。”
他请你把副本留下，答应逐条写清当晚看见和听见的事。''','npc-he',requires=[known('medical'),known('rescue'),known('he_first')],target='he')
action('call_station','接通避风站，确认江临安全','boathouse','''听筒里响了一阵杂音，有人问：“潮退了吗？”
你照着邀请信背面问出口令。那人答：“把名字留在岸上。”随后说起上一封信里讨论过的章节。是江临。
“我在护林员这儿。跟林素吵完，怕她拿走材料，就先走了。腿没事，路上慢了点。”
你问起九声钟。他沉默片刻：“我设的。想让你们多留一会儿。抱歉，让你们这么找。”
他答应天亮后带着录音和稿纸回来，也同意交出副本：“陈雾那本病历，只用相关的那页。”
护林员接过电话，报了站点和通话登记编号。你记下号码，再把江临平安的消息告诉何泊。他松开握着拐杖的手，靠回椅背。''','cg-dawn',requires=[known('witness'),known('rope')],effects=[reveal('contact'),setflag('protected')])
action('confront_lin','拿三份材料回访林素','lobby','''你把护理页、两份名单和未寄信摆上接待台。
“赵世衡回来过。你什么时候知道的？”
林素没有拿起纸。她看了一会儿，点头：“当晚就知道。副本是我改的，丁远让我改。我也怕旅馆保不住。”
你再问断电。她说，今晚22:55去了机房，剪断控制线，想让江临放不了旧录音。后来发短信叫赵朔来修，谎称机房进水。
“江临呢？”她问。
这张台面上能说明的事，你逐一问完。林素从柜台下取出另一只文件袋，推过来。
“剩下的在这里。”她没松手，“赵朔会看见吗？”
你将袋子接过来。她低下头，手停在半空，慢慢收了回去。''','npc-lin',requires=[known('medical'),known('register'),known('letter'),known('wire')],effects=[reveal('lin_confess'),{'op':'grant','ref':'lin_documents'}],target='lin')
action('reconstruct','把两条时间线放到桌上','lounge','''餐桌擦干了，今夜的记录放在左边，2008年的放在右边。
今夜：21:17停钟；22:55断电；23:12报修；23:25江临走后山；23:40音箱播放钟声。避风站的电话已经接通，江临还活着。
十五年前：22:10赵世衡被救回岸上；22:35被带离；23:05丁远命令暂停搜寻。副本后来改成了“海上失联”。再往后的那段，几份材料都没能补全。
陈雾用笔圈出护理页的签名。赵朔把父亲的名字写在目录上，何泊坐着等你问话。林素将文件袋放在桌边。
录音和副本已收好。是现在交出材料、公开报道，还是先封存，留七天继续核实？赵朔看着你，等你开口。''','cg-confrontation',requires=[known('clock'),known('schedule'),known('recording'),known('medical'),known('rescue'),known('lin_confess'),known('contact'),flag('copied')],effects=[reveal('reconstruction')])
for id,label,decision,text in [
('publish_truth','提交原件，播出核实后的调查','truth','你请四位当事人逐页确认记录，将原件装入交接袋。用于报道的副本另放一边，无关病人的姓名遮住，读不出的半句仍留在原处。'),
('seal_handover','先封存交接，约定七日内核实跟进','sealed','你拿出封存袋，写好交接目录。赵朔问要等多久，你在交接单上写下七天后的日期，将联系人和电话一并交给他。'),
('accuse_murder','把林素直接指为今夜的杀人者','false','你在稿件里写下“林素杀害江临”。陈雾看见那一行，将应急通话登记推到你面前：“刚才电话里那个人，你也听见了。”你没有改掉那句话，按下发送。')]:
 action(id,label,'lounge',text,'cg-confrontation',requires=[known('reconstruction'),flag('decision','')],effects=[setflag('decision',decision)])
action('leave_early','停止追查，等待天亮离岛','lobby','''你把笔记收进包里，告诉林素，天亮就走。
她拿出渡船恢复通航的通知，放在接待台上，没有问原因。
录音笔还剩一点电。你关掉它，雨声一下显得很近。已经拿到的材料都在包里，没问完的话也留在纸上。
门口的铃被风碰了一下。你站了一会儿，才转身上楼。''','lobby',effects=[setflag('decision','leave')])
endings={
 'truth':('shore_names','名字留在岸上','''天亮后，江临从山上下来，外套下摆全是泥。他坐到餐桌前，听完磁带，逐页认了稿纸。
赵朔将父亲的名字写在证据目录第一行。陈雾留下护理页的副本，何泊写下当晚的经过。林素签名时，笔尖在纸上停了很久。
材料交出去了。报道写到22:35被带离，写到暂停搜救和修改名单；后间那段残缺的记录，仍等着有人查清。
旅馆暂时关门。赵朔收好交接单，没有和林素道别。
渡船靠岸时响了一声铃。你按下录音键，江临站在旁边，终于没有再让任何声音替自己传话。'''),
 'sealed':('seven_days','七日之约','''原件装进封存袋，目录逐页签过，副本分别留下。交接单最后一栏写着跟进日期：七天以后。
“七天。”赵朔读了一遍，“到时候我找谁？”
你把联系人和电话写给他，也留下一份完整录音。江临说会一起跟进，陈雾将护理册锁回抽屉。
何泊在门外等船。林素把餐桌上的纸屑收进掌心，没有来送。
你将七天后的日期记进本子。那一页还空着。'''),
 'false':('loud_error','最响的错误','''报道发出后，江临打来电话。
“你说她今晚杀了我？”
你面前还摊着避风站的通话登记。报修短信、护理页和那盘磁带，都被你用来拼成了另一个故事。
赵朔把报道链接发来，只问了一句：“那我爸的事，现在还有谁肯信？”
你撤下报道，写更正，逐个联系交过材料的人。有的电话接通了，有的响到最后也没人接。
磁带仍留在桌上。第九声钟，和第八声一模一样。'''),
 'leave':('unanswered','尚未问完的雨夜','''天亮后，林素把钥匙重新挂上板。你背着包穿过接待厅，渡船在码头等着。
笔记里记了几个人名、几个时间，还有没来得及问的问题。纸夹在包里，被潮气浸得发软。
船离岸时，你回头看。旧船屋的门开着，何泊站在石阶上。再远一些，旅馆二楼的窗户反着光，看不见里面。
手机恢复了信号。你翻开行前笔记，重新读了一遍。''')}
for decision,(id,label,text) in endings.items():
 media(id,label+'\n\n'+text,'cg-dawn' if decision in ('truth','sealed') else 'cg-confrontation')
 s['events'].append({'id':'end_'+decision,'trigger':'step_end','priority':100,'once':True,'condition':flag('decision',decision),'effects':[{'op':'end','value':id}]})
media('storm_passed','调查暂时中止\n\n天已经亮了，码头传来渡船的汽笛。你将散在桌上的纸页收好，有几处时间还没对上，也有几句话来不及再问。已取得的记录留在手记里，这次调查到这里暂告一段落。','cg-dawn')
s['events'].append({'id':'fallback','trigger':'round_end','priority':1,'once':True,'condition':{'op':'gte','ref':'clock.round','value':24},'effects':[{'op':'end','value':'storm_passed'}]})
media('blackout','''楼下灯灭了一瞬，应急红灯随即亮起。有人在接待台说“又来了”，却没有解释“又”指的是哪一次。
林素摸到台边的手电，光柱扫过楼梯，又移向机房入口。餐厅、走廊和船屋仍有人回应。应急灯下，摊开的纸页泛着红光。''','cg-blackout')
s['events'].append({'id':'blackout_at_four','trigger':'round_end','priority':50,'once':True,'condition':{'op':'eq','ref':'clock.round','value':4},'effects':[{'op':'cue','ref':'blackout','audience':'all','blocking':True}]})
s['c3']['interactions']=[
{'id':'cabinet_password','target_id':'cabinet','kind':'password','cost':1,'attempts':{'scope':'actor','max':6,'reset_event':None},'on_success':[{'op':'set_flag','ref':'cabinet_open','value':True}],'on_failure':[],'audience':'actor','format':'pin','normalization':'exact','min_length':4,'max_length':4,'answer_secret_ref':'cabinet_code'},
{'id':'repair_switchboard','target_id':'switchboard','kind':'check','cost':1,'attempts':{'scope':'actor','max':1,'reset_event':None},'on_success':[{'op':'set_flag','ref':'power','value':True}],'on_failure':[],'audience':'actor','base_target':70,'modifiers':[],'formula':'1d100_lte'}]
s['c3_settings']['interaction_labels']={'cabinet_password':{'label':'输入铁柜密码','risk_text':'按封存日的月日输入四位数字。每次错误消耗1点余力，最多尝试六次。也可按维护页拆锁。'},'repair_switchboard':{'label':'尝试修复隔离后的控制电源','risk_text':'成功率70%；无论结果如何，均可手动读取封存计时卡。不会损坏证据。'}}
s['c3_settings']['objectives']=[{'id':'find_jiang','label':'确认江临此刻安全','layer':'personal','role_ids':['reporter'],'condition':flag('protected'),'latch':True,'membership_policy':'follow_current'},{'id':'keep_records','label':'保存旧案互证副本','layer':'personal','role_ids':['reporter'],'condition':flag('copied'),'latch':True,'membership_policy':'follow_current'}]
# Conditional interaction results have distinct narrative and images, not bare AP messages.
for id,ref,img,text in [('cabinet_success','cabinet_open','evidence-registry','机械锁舌退回，柜门缓缓打开。最上面压着救援命令，下面露出一只没有写地址的信封。'),('power_success','power','evidence-fuse','隔离后的控制电源恢复，维修时间表再次可读。记录与纸质计时卡一致：22:55断电，23:12报修。赵朔将这两项抄到纸上，递给你。')]:
 media(id,text,img)
 s['events'].append({'id':id,'trigger':'action_end','priority':30,'once':True,'condition':flag(ref),'effects':[{'op':'cue','ref':id,'audience':'all','blocking':True}]})
for a in s['actions']:
 if a['id'] in ('publish_truth','seal_handover','accuse_murder','leave_early'): a['risk_text']='确认将结束本次故事；返回可继续调查。'+a['label']+'。'
# Flexible attendance: every selected role can investigate the complete case.
role_specs=json.loads((ROOT/'content/c3/tide_hotel/roles.json').read_text())
s['roles']=[]
s['initial']['inventory']={}
s['c3_settings']['action_roles']={}
end_ids=['shore_names','seven_days','loud_error','unanswered','storm_passed']
for role in role_specs:
 rid=role['id']
 label={'reporter':'徐闻 · 声音记者','archivist':'沈砚 · 地方档案研究员','volunteer':'许澄 · 救援志愿者','photographer':'陆遥 · 纪实摄影师'}[rid]
 cid='brief_'+rid
 clue(cid,label+' · 私人角色本',role['opening'],role['image'])
 s['clues'][-1]['shareable']=True
 intro='role_opening_'+rid
 media(intro,role['opening'],role['image'])
 s['media'][-1]['audience']=[rid]
 epilogues={}
 overrides={}
 for ending in end_ids:
  mid='epilogue_'+rid+'_'+ending
  text=role['endings'][ending]
  media(mid,text+'\n\n'+role['kept'],role['image'])
  s['media'][-1]['audience']=[rid]
  epilogues[ending]=mid
  media(mid+'_shared',text+'\n\n'+role['shared'],role['image'])
  s['media'][-1]['audience']=[rid]
  overrides[ending]={'condition':flag('done_disclose_'+rid),'media':mid+'_shared'}
 s['roles'].append({'id':rid,'label':label,'description':role['description'],'location':'lobby','knowledge':[cid],
  'goals':['找到江临，核对他今晚的行踪。',role['goal']],
  'opening_media':intro,'epilogues':epilogues,'epilogue_overrides':overrides})
 s['initial']['inventory'][rid]=[]
 for chapter,trigger in [(2,'ask_chen_oldcase'),(3,'copy_evidence')]:
  mid='memory_'+rid+'_'+str(chapter)
  clue(mid,label+' · 第'+str(chapter)+'幕回忆',role['chapter'+str(chapter)],role['image'])
  s['clues'][-1]['shareable']=True
  media(mid,'第'+str(chapter)+'幕 · '+label.split(' · ')[0]+'的回忆（仅自己可见）\n\n'+role['chapter'+str(chapter)],role['image'])
  s['media'][-1]['audience']=[rid]
  s['events'].append({'id':mid,'trigger':'action_end','priority':20,'once':True,'condition':flag('done_'+trigger),
   'effects':[{'op':'reveal','ref':mid,'audience':[rid]},{'op':'cue','ref':mid,'audience':[rid],'blocking':True}]})
 aid='disclose_'+rid
 action(aid,role['disclose_label'],'lounge',role['disclose'],role['image'],requires=[known('memory_'+rid+'_3')])
 s['c3_settings']['action_roles'][aid]=[rid]
 s['c3_settings']['objectives'].append({'id':'personal_'+rid,'label':role['goal'],'layer':'personal','role_ids':[rid],
  'condition':flag('done_'+aid),'latch':True,'membership_policy':'follow_current'})
media('chapter_oldcase','第二幕 · 岸上的名字\n\n护理室找到了十五年前的记录。江临追查的旧事有了实物，参与调查的人可以交换各自发现，再去问当年的在场者。','evidence-medical')
media('chapter_handover','第三幕 · 留下什么\n\n旧案材料已有副本。雨渐渐小了，海景餐厅的桌子已经腾空。带着找到的东西回来，有些话还要当面讲。','lounge')
for mid,trigger in [('chapter_oldcase','ask_chen_oldcase'),('chapter_handover','copy_evidence')]:
 s['events'].append({'id':mid,'trigger':'action_end','priority':10,'once':True,'condition':flag('done_'+trigger),
  'effects':[{'op':'cue','ref':mid,'audience':'all','blocking':True}]})
s['c3_settings']['min_players']=1
s['c3_settings']['coalesce_actions']=True
s['c3_settings']['team_decisions']=['publish_truth','seal_handover','accuse_murder','leave_early']
for a in s['actions']:
 if a['id'] in s['c3_settings']['team_decisions']:
  a['risk_text']='单人确认即可结束；多人需要全员在同一地点选择同一方案。一人提交不会单方面结束故事。'+a['label']+'。'
for c in s['clues']: c['shareable']=True
# Discoveries and their narration stay with the investigators present; sharing is explicit.
for a in s['actions']:
 marker='done_'+a['id']
 s['initial']['world'][marker]=False
 a['condition']=allof(a['condition'],flag(marker,False))
 a['display_condition']=a['condition']
 a['effects'].append(setflag(marker))
 for e in a['effects']:
  if e['op'] in ('reveal','cue'): e['audience']='scene'
for o in s['c3_settings']['objectives']:
 if not o['id'].startswith('personal_'):
  o['layer']='public';o['role_ids']=[]
media('cover','1～4人悬疑 · 预计30–60分钟 · 四位当事人 · 八个场景 · 五个结局','cover')
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
