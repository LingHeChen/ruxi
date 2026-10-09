"""C2 offline reference interpreter. Deterministic action subset only; no networking/AI/DB."""
import copy,json
from pathlib import Path
class Engine:
 def __init__(self,s):
  self.s=copy.deepcopy(s);self.world=copy.deepcopy(s['initial']['world']);self.round=1;self.step=1;self.ending=None;self.fired=set();self.trace=[]
  self.actors={r['id']:{'loc':r['location'],'ap':s['rules']['ap_per_round'],'known':set(r['knowledge']),'inventory':set(s['initial']['inventory'].get(r['id'],[])),'used':{}} for r in s['roles']}
 def read(self,ref,actor):
  if ref.startswith('world.'):return self.world[ref[6:]]
  return {'actor.location':self.actors[actor]['loc'],'actor.ap':self.actors[actor]['ap'],'clock.round':self.round}[ref]
 def cond(self,c,actor):
  op=c['op'];a=self.actors[actor]
  if op=='all':return all(self.cond(x,actor) for x in c['args'])
  if op=='any':return any(self.cond(x,actor) for x in c['args'])
  if op=='not':return not self.cond(c['args'][0],actor)
  if op=='has_knowledge':return c['ref'] in a['known']
  if op=='owns':return c['ref'] in a['inventory']
  x=self.read(c['ref'],actor);y=c['value']
  if op=='eq':return type(x)==type(y) and x==y
  if op=='ne':return not(type(x)==type(y) and x==y)
  if op=='gte':return x>=y
  if op=='lte':return x<=y
  raise ValueError(op)
 def effects(self,es,actor):
  a=self.actors[actor]
  for e in es:
   if e['op']=='set':self.world[e['ref'][6:]]=e['value']
   elif e['op']=='move':a['loc']=e['value']
   elif e['op']=='reveal':
    for p in self.actors.values() if e['audience']=='all' else [a]:p['known'].add(e['ref'])
   elif e['op']=='grant':a['inventory'].add(e['ref'])
   elif e['op']=='end':self.ending=self.ending or e['value']
 def events(self,trigger):
  actor=next(iter(self.actors))
  for _ in range(32):
   fired=False
   for e in sorted(self.s['events'],key=lambda e:(e['priority'],e['id'])):
    if e['trigger']==trigger and e['id'] not in self.fired and self.cond(e['condition'],actor):
     if e['once']:self.fired.add(e['id'])
     self.effects(e['effects'],actor);fired=True
     if self.ending:return
   if not fired:return
  raise ValueError('RULE_LOOP')
 def action(self,actor,id):
  a=self.actors[actor]
  if id=='pass':a['ap']=0;return 'passed'
  if id.startswith('move:'):
   link=next(x for x in self.s['links'] if x['id']==id[5:]);act={'cost':link['cost'],'location':link['from'],'condition':link['condition'],'effects':[{'op':'move','value':link['to']}],'max_uses':999}
  else:act=next(x for x in self.s['actions']+self.s['templates'] if x['id']==id)
  if a['loc']!=act['location'] or a['ap']<act['cost'] or not self.cond(act['condition'],actor) or a['used'].get(id,0)>=act['max_uses']:return 'invalidated'
  if any(e['op']=='grant' and any(e['ref'] in p['inventory'] for p in self.actors.values()) for e in act['effects']):return 'invalidated'
  if act.get('threshold') is not None:raise ValueError('Reference subset excludes probabilistic actions')
  a['ap']-=act['cost'];a['used'][id]=a['used'].get(id,0)+1;self.effects(act['effects'],actor);self.events('action_end');return 'resolved'
 def resolve(self,intents):
  if self.ending:raise ValueError('already ended')
  roles=list(self.actors);start=(self.round+self.step-2)%len(roles);order=roles[start:]+roles[:start];result=[]
  before=copy.deepcopy(self.__dict__)
  try:
   for actor in order:
    if self.actors[actor]['ap']>0:result.append((actor,self.action(actor,intents.get(actor,'pass'))))
   self.events('step_end');self.trace.append({'round':self.round,'step':self.step,'order':order,'result':result,'world':copy.deepcopy(self.world)})
   if not self.ending:
    if self.step>=self.s['rules']['ap_per_round'] or all(a['ap']==0 for a in self.actors.values()):
     self.events('round_end')
     if not self.ending:
      self.round+=1;self.step=1
      for a in self.actors.values():a['ap']=self.s['rules']['ap_per_round']
    else:self.step+=1
  except Exception:
   self.__dict__=before;raise
  return result
 def visible(self,actor):
  a=self.actors[actor];return {'location':a['loc'],'ap':a['ap'],'known':sorted(a['known']),'inventory':sorted(a['inventory']),'ending':self.ending}
def semantic_errors(s):
 errors=[];sets={k:{x['id'] for x in s[k]} for k in ['roles','locations','links','objects','clues','actions','templates','events','media']}
 for k in sets:
  if len(sets[k])!=len(s[k]):errors.append('DUPLICATE_ID:'+k)
 for k in ['roles','objects','actions','templates']:
  for i,x in enumerate(s[k]):
   if x['location'] not in sets['locations']:errors.append(f'UNKNOWN_LOCATION:/{k}/{i}/location')
 for x in s['roles']:
  if any(c not in sets['clues'] for c in x['knowledge']):errors.append('UNKNOWN_CLUE')
 for x in s['links']:
  if x['from'] not in sets['locations'] or x['to'] not in sets['locations']:errors.append('UNKNOWN_LINK_LOCATION')
 def cond(c):
  if 'args' in c:
   for x in c['args']:cond(x)
  elif c['op'] in ['has_knowledge','owns']:
   if c['ref'] not in sets['clues' if c['op']=='has_knowledge' else 'objects']:errors.append('UNKNOWN_ENTITY')
  elif c['ref'].startswith('world.'):
   if c['ref'][6:] not in s['initial']['world']:errors.append('UNKNOWN_STATE_REF')
  elif c['ref'] not in ['actor.location','actor.ap','clock.round']:errors.append('UNKNOWN_STATE_REF')
 for k in ['actions','templates','events','links']:
  for x in s[k]:
   cond(x['condition'])
   for e in x.get('effects',[])+x.get('failure',[]):
    if e['op']=='set' and (not e['ref'].startswith('world.') or e['ref'][6:] not in s['initial']['world']):errors.append('UNKNOWN_STATE_REF')
    if e['op']=='reveal' and e['ref'] not in sets['clues']:errors.append('UNKNOWN_CLUE')
    if e['op']=='grant' and e['ref'] not in sets['objects']:errors.append('UNKNOWN_ITEM')
    if e['op']=='end' and (k!='events' or x['trigger'] not in ['step_end','round_end']):errors.append('INVALID_END_PHASE')
 return errors
if __name__=='__main__':
 s=json.loads((Path(__file__).parent.parent/'examples/restaurant.json').read_text());e=Engine(s)
 for action in ['ask','move:dining_hall','unlock','move:hall_kitchen','switch_off']:e.resolve({'guest':action})
 print(json.dumps({'ending':e.ending,'trace':e.trace},ensure_ascii=False,indent=2))
