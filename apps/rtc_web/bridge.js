import RTC, {MediaType, RoomProfileType, StreamIndex} from '@volcengine/rtc';
let engine=null, epoch=0, callback=null, microphone=false, captureEpoch=0, peers=new Set();
function emit(type,data={}) { callback?.(JSON.stringify({type,...data})); }
async function mute() {
  ++captureEpoch; microphone=false;
  const current=engine;
  if (!current) return;
  // Stop capture before awaiting signalling. No microphone survives a lost focus.
  try { await current.stopAudioCapture(); } catch {}
  try { await current.unpublishStream(MediaType.AUDIO); } catch {}
  emit('muted');
}
async function leave() {
  ++epoch; ++captureEpoch;
  const old=engine; engine=null; microphone=false; callback=null; peers.clear();
  if (old) {
    try { await old.stopAudioCapture(); } catch {}
    try { await old.leaveRoom(); } catch {}
    RTC.destroyEngine(old);
  }
}
window.ruxiRTC={
  async join(raw, handler) {
    await leave();
    const grant=JSON.parse(raw), generation=++epoch;
    callback=handler;
    const current=engine=RTC.createEngine(grant.app_id);
    current.on('onConnectionStateChanged', ({state})=>{
      if(generation!==epoch) return;
      if(state===5) {void mute(); emit('connected');}
      else if(state===1 || state===4 || state===6) { void mute(); emit('disconnected'); }
    });
    current.on('onError', ()=> { if(generation===epoch){void mute();emit('failed');} });
    current.on('onUserJoined', ({userInfo})=>{ if(generation===epoch && userInfo?.userId) peers.add(userInfo.userId); });
    current.on('onUserLeave', ({userId})=>peers.delete(userId));
    current.on('onTokenWillExpire', ()=> { if(generation===epoch) emit('renew'); });
    current.on('onAudioVolumeIndication', (event)=>{
      if(generation===epoch) emit('levels',{speakers:event.speakers??[]});
    });
    current.setAudioVolumeIndicationInterval(200);
    try {
      await current.joinRoom(grant.token,grant.rtc_room_id,{userId:grant.rtc_uid},{roomProfileType:RoomProfileType.chatRoom,isAutoPublish:false,isAutoSubscribeAudio:true,isAutoSubscribeVideo:false});
      if(generation!==epoch) { await current.leaveRoom(); return; }
      emit('connected');
    } catch { if(generation===epoch) {await leave();throw new Error('RTC_JOIN_FAILED');} }
  },
  async mic(enabled) {
    if(!enabled) return mute();
    const current=engine, generation=epoch, intent=++captureEpoch;
    if(!current) throw new Error('RTC_NOT_CONNECTED');
    try {
      await current.startAudioCapture();
      if(intent!==captureEpoch || generation!==epoch || document.hidden || !document.hasFocus()) {await current.stopAudioCapture();return;}
      await current.publishStream(MediaType.AUDIO);microphone=true;
    } catch { await mute(); throw new Error('MIC_PERMISSION_OR_DEVICE'); }
  },
  async renew(token) {if(engine) await engine.updateToken(token);},
  volume(uid, volume) {if(engine) engine.setPlaybackVolume(uid,StreamIndex.STREAM_INDEX_MAIN,Math.round(volume*100));},
  leave,
};
addEventListener('blur', ()=>{void mute();emit('focus_lost');});
addEventListener('pagehide', ()=>void leave());
document.addEventListener('visibilitychange',()=>{if(document.hidden){emit('background');void leave();}});
navigator.mediaDevices?.addEventListener('devicechange',()=>{void mute();emit('device_changed');});
