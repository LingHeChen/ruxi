import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
const source=(await readFile(new URL('../bridge.js',import.meta.url),'utf8')).replace(/^import .*;\n/,'');
function fixture(){
 const listeners={},events=[],handlers={};let stops=0,unpublishes=0,publishes=0,leaves=0;
 const engine={on:(n,f)=>handlers[n]=f,setAudioVolumeIndicationInterval(){},async joinRoom(){},async stopAudioCapture(){stops++;},async unpublishStream(){unpublishes++;},async leaveRoom(){leaves++;},async startAudioCapture(){},async publishStream(){publishes++;}};
 const window={}, document={hidden:false,hasFocus:()=>true,addEventListener(){}};
 vm.runInNewContext(source,{RTC:{createEngine:()=>engine,destroyEngine(){}},MediaType:{AUDIO:1},RoomProfileType:{chatRoom:1},StreamIndex:{STREAM_INDEX_MAIN:0},window,document,navigator:{},addEventListener:(n,f)=>listeners[n]=f});
 return {bridge:window.ruxiRTC,handlers,listeners,events,engine,counts:()=>({stops,unpublishes,publishes,leaves})};
}
test('capture permission error keeps room and idle blur does not unpublish',async()=>{
 const f=fixture();await f.bridge.join(JSON.stringify({app_id:'test',token:'test',rtc_room_id:'room',rtc_uid:'user'}),x=>f.events.push(JSON.parse(x)));
 f.handlers.onError({errorCode:'NO_PERMISSION'});f.listeners.blur();await new Promise(r=>setImmediate(r));
 assert(!f.events.some(e=>e.type==='failed'));assert(f.events.some(e=>e.type==='microphone_error'));assert.equal(f.counts().leaves,0);assert.equal(f.counts().unpublishes,0);
});
test('blur during permission prompt cancels capture without publishing',async()=>{
 const f=fixture();await f.bridge.join(JSON.stringify({}),x=>f.events.push(JSON.parse(x)));
 let finish;f.engine.startAudioCapture=()=>new Promise(r=>finish=r);
 const pending=f.bridge.mic(true);f.listeners.blur();finish();await pending;
 assert.equal(f.counts().publishes,0);assert.equal(f.counts().leaves,0);
});
test('provider room removal still invalidates the session',async()=>{
 const f=fixture();await f.bridge.join('{}',x=>f.events.push(JSON.parse(x)));
 f.handlers.onError({errorCode:'ROOM_DISMISS'});assert(f.events.some(e=>e.type==='failed'));
});
