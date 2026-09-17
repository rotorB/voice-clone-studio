from __future__ import annotations

import asyncio
import fcntl
import gc
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from collections import deque
from datetime import datetime
from pathlib import Path

try:
    import gradio as gr
except ModuleNotFoundError:
    gr = None
import mlx.core as mx
import numpy as np
import soundfile as sf
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from mlx_audio.stt import load as load_stt
from mlx_audio.tts.utils import load_model
import uvicorn


ROOT = Path(__file__).resolve().parent
OUTPUT_DIR = Path(os.environ.get("VOICE_CLONE_OUTPUT_DIR", ROOT / "output")).expanduser()
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

DESIGN_MODEL = "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit"
CLONE_MODEL = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit"
ASR_MODEL = "mlx-community/Qwen3-ASR-0.6B-8bit"
MIN_RECORDING_RMS = 0.008
MIN_ACTIVE_AUDIO_RATIO = 0.05
LIVE_PORT = 7861
LIVE_VAD_RMS = 0.0045
LIVE_PAUSE_SECONDS = 0.45
LIVE_MIN_SPEECH_SECONDS = 0.22

MODEL = None
MODEL_ID: str | None = None
STT_MODEL = None
STT_MODEL_ID: str | None = None
MODEL_LOCK = threading.Lock()
REFERENCE_STATE_LOCK = threading.Lock()
VOICE_LIBRARY_LOCK = threading.Lock()
WEB_PROCESS_LOCK = None
WEBSOCKET_REFERENCE_AUDIO: str | None = None
WEBSOCKET_REFERENCE_TEXT = ""
WEBSOCKET_REFERENCE_LANGUAGE: str | None = None
REFERENCE_STATE_PATH = OUTPUT_DIR / ".reference.json"
VOICE_LIBRARY_DIR = OUTPUT_DIR / "voice-library"
VOICE_LIBRARY_PATH = VOICE_LIBRARY_DIR / "voices.json"


class RuntimeMetrics:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.active_operation = "idle"
        self.requests_total = 0
        self.response_seconds = 0.0
        self.bytes_in = 0
        self.bytes_out = 0
        self.asr_count = 0
        self.asr_seconds = 0.0
        self.last_asr_ms = 0
        self.tts_count = 0
        self.tts_seconds = 0.0
        self.last_tts_ms = 0
        self.last_error = ""

    def active(self, operation: str) -> None:
        with self.lock:
            self.active_operation = operation

    def idle(self) -> None:
        with self.lock:
            self.active_operation = "idle"

    def response(self, elapsed: float) -> None:
        with self.lock:
            self.requests_total += 1
            self.response_seconds += elapsed

    def traffic(self, incoming: int = 0, outgoing: int = 0) -> None:
        with self.lock:
            self.bytes_in += incoming
            self.bytes_out += outgoing

    def asr(self, elapsed: float) -> None:
        with self.lock:
            self.asr_count += 1
            self.asr_seconds += elapsed
            self.last_asr_ms = round(elapsed * 1000)

    def tts(self, elapsed: float) -> None:
        with self.lock:
            self.tts_count += 1
            self.tts_seconds += elapsed
            self.last_tts_ms = round(elapsed * 1000)

    def error(self, error: object) -> None:
        with self.lock:
            self.last_error = str(error)[:240]

    def snapshot(self, started_at: float) -> dict:
        with self.lock:
            uptime = max(0.001, time.time() - started_at)
            return {
                "active_operation": self.active_operation,
                "uptime_seconds": round(uptime),
                "requests_total": self.requests_total,
                "average_response_ms": round(
                    1000 * self.response_seconds / self.requests_total
                ) if self.requests_total else 0,
                "bytes_in": self.bytes_in,
                "bytes_out": self.bytes_out,
                "traffic_kbps": round((self.bytes_in + self.bytes_out) / 1024 / uptime, 2),
                "last_asr_ms": self.last_asr_ms,
                "average_asr_ms": round(
                    1000 * self.asr_seconds / self.asr_count
                ) if self.asr_count else 0,
                "last_tts_ms": self.last_tts_ms,
                "average_tts_ms": round(
                    1000 * self.tts_seconds / self.tts_count
                ) if self.tts_count else 0,
                "last_error": self.last_error,
            }


METRICS = RuntimeMetrics()


def _normalize_language(value: object) -> str | None:
    if isinstance(value, (list, tuple)):
        value = next((item for item in value if item), None)
    language = str(value or "").strip().lower()
    aliases = {
        "en": "English", "english": "English",
        "ru": "Russian", "russian": "Russian",
        "es": "Spanish", "spanish": "Spanish",
        "de": "German", "german": "German",
        "fr": "French", "french": "French",
        "it": "Italian", "italian": "Italian",
        "pt": "Portuguese", "portuguese": "Portuguese",
        "zh": "Chinese", "chinese": "Chinese",
        "ja": "Japanese", "japanese": "Japanese",
        "ko": "Korean", "korean": "Korean",
    }
    return aliases.get(language)


def _text_language(text: str, fallback: str | None = None) -> str:
    cyrillic = sum("\u0430" <= char.lower() <= "\u044f" or char.lower() == "\u0451" for char in text)
    latin = sum("a" <= char.lower() <= "z" for char in text)
    if cyrillic > latin:
        return "Russian"
    if latin:
        return "English"
    return fallback or "Russian"


def _set_reference(audio: str | None, text: str, language: str | None = None) -> None:
    global WEBSOCKET_REFERENCE_AUDIO, WEBSOCKET_REFERENCE_TEXT, WEBSOCKET_REFERENCE_LANGUAGE
    clean_text = text.strip()
    WEBSOCKET_REFERENCE_AUDIO = audio
    WEBSOCKET_REFERENCE_TEXT = clean_text
    if language:
        WEBSOCKET_REFERENCE_LANGUAGE = language
    if not audio or not clean_text:
        return
    with REFERENCE_STATE_LOCK:
        temporary = REFERENCE_STATE_PATH.with_suffix(".tmp")
        temporary.write_text(
            json.dumps(
                {
                    "audio": str(audio),
                    "text": clean_text,
                    "language": WEBSOCKET_REFERENCE_LANGUAGE,
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        os.replace(temporary, REFERENCE_STATE_PATH)


def _restore_reference() -> None:
    global WEBSOCKET_REFERENCE_AUDIO, WEBSOCKET_REFERENCE_TEXT, WEBSOCKET_REFERENCE_LANGUAGE
    if WEBSOCKET_REFERENCE_AUDIO and WEBSOCKET_REFERENCE_TEXT:
        return
    try:
        payload = json.loads(REFERENCE_STATE_PATH.read_text(encoding="utf-8"))
        audio = str(payload["audio"])
        text = str(payload["text"]).strip()
        if Path(audio).is_file() and text:
            WEBSOCKET_REFERENCE_AUDIO = audio
            WEBSOCKET_REFERENCE_TEXT = text
            WEBSOCKET_REFERENCE_LANGUAGE = _normalize_language(payload.get("language"))
    except (FileNotFoundError, KeyError, TypeError, ValueError, json.JSONDecodeError):
        return


def _load_voice_library() -> list[dict]:
    try:
        voices = json.loads(VOICE_LIBRARY_PATH.read_text(encoding="utf-8"))
        if not isinstance(voices, list):
            return []
        return [
            voice for voice in voices
            if isinstance(voice, dict) and Path(str(voice.get("audio", ""))).is_file()
        ]
    except (FileNotFoundError, TypeError, ValueError, json.JSONDecodeError):
        return []


def _save_voice_library(voices: list[dict]) -> None:
    VOICE_LIBRARY_DIR.mkdir(parents=True, exist_ok=True)
    temporary = VOICE_LIBRARY_PATH.with_suffix(".tmp")
    temporary.write_text(json.dumps(voices, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(temporary, VOICE_LIBRARY_PATH)

# Qwen3-TTS Base does not accept VoiceDesign/CustomVoice instructions. These
# controls are deliberately implemented as transparent post-processing, not as
# a hidden prompt that the cloning model would ignore.
EMOTION_FX = {
    "As in the reference": {"tempo": 1.0, "pitch": 0.0, "gain": 0.0},
    "Joy": {"tempo": 1.07, "pitch": 0.9, "gain": 0.8},
    "Sadness": {"tempo": 0.88, "pitch": -0.7, "gain": -1.5},
    "Anger": {"tempo": 1.04, "pitch": -0.35, "gain": 1.8, "compress": True},
    "Fear": {"tempo": 1.10, "pitch": 1.1, "gain": -0.3, "tremolo": True},
    "Calm": {"tempo": 0.93, "pitch": -0.25, "gain": -0.8},
}

EMOTION_ALIASES = {
    "as in the reference": "As in the reference",
    "neutral": "As in the reference",
    "joy": "Joy",
    "sadness": "Sadness",
    "anger": "Anger",
    "fear": "Fear",
    "calm": "Calm",
}


def _emotion_key(name: str) -> str:
    name = str(name or "").strip()
    return name if name in EMOTION_FX else EMOTION_ALIASES.get(name.lower(), "As in the reference")


LIVE_CLIENT_JS = r"""
() => {
  const init = () => {
    const root = document.querySelector('#realtime-voice');
    if (!root || root.dataset.ready) return false;
    root.dataset.ready = '1';
    const $ = id => document.getElementById(id);
    let socket, context, processor, inputStream, captureStream, outputRate = 24000;
    let sampleCapture, sampleContext, sampleProcessor, sampleAnalyser, sampleAudio, sampleRate = 44100, sampleChunks = [], sampleCount = 0;
    let spectrogram = [], dragStart = null, dragOriginX = 0, dragMoved = false;
    let previewContext, previewBuffer, previewSource, previewStartedAt = 0, previewOffset = 0, previewEnd = 0, previewFrame = 0, playhead = 0;
    let liveStarting = false, liveReady = false, liveSession = 0;
    let textReferenceReady = false, textGenerating = false, textPoll;
    let busy = false, sawSpeech = false, speechRun = 0, silence = 0, nextPlayback = 0, phraseStarted = 0;
    let sources = new Set(), unlockTimer;
    const channel = 'BroadcastChannel' in window ? new BroadcastChannel('qwen-live') : null;
    const state = (name, message) => {
      root.dataset.state = name; $('rt-state').textContent = name; $('rt-status').textContent = message;
    };
    const metric = (id, value) => { $(id).textContent = value; };
    const resetPhrase = () => { busy = false; sawSpeech = false; speechRun = 0; silence = 0; phraseStarted = 0; };
    const acquireSource = async mode => {
      if(mode==='system'){
        const capture=await navigator.mediaDevices.getDisplayMedia({video:true,audio:true,systemAudio:'include'});
        const tracks=capture.getAudioTracks();
        if(!tracks.length){capture.getTracks().forEach(t=>t.stop());throw new Error('No audio track was provided. Enable audio in the Share dialog.');}
        return {capture,input:new MediaStream(tracks),label:'System audio'};
      }
      const capture=await navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:true,noiseSuppression:true,autoGainControl:true}});
      return {capture,input:capture,label:'Microphone'};
    };
    const play = arrayBuffer => {
      const pcm = new Int16Array(arrayBuffer);
      const buffer = context.createBuffer(1, pcm.length, outputRate);
      const channelData = buffer.getChannelData(0);
      for (let i = 0; i < pcm.length; i++) channelData[i] = pcm[i] / 32768;
      const source = context.createBufferSource(); source.buffer = buffer; source.connect(context.destination);
      source.onended = () => sources.delete(source); sources.add(source);
      nextPlayback = Math.max(context.currentTime + 0.025, nextPlayback);
      source.start(nextPlayback); nextPlayback += buffer.duration;
      metric('rt-queue', Math.max(0, nextPlayback - context.currentTime).toFixed(1) + ' c');
    };
    const stop = (silent = false) => {
      liveSession++; liveStarting=false; liveReady=false;
      clearTimeout(unlockTimer); processor?.disconnect(); captureStream?.getTracks().forEach(t => t.stop());
      if (socket?.readyState < 2) socket.close(); sources.forEach(s => { try { s.stop(); } catch {} }); sources.clear();
      socket = processor = inputStream = captureStream = null; nextPlayback = 0; resetPhrase();
      $('rt-start').disabled = false; $('rt-start').textContent='● Start'; $('rt-stop').disabled = true; $('rt-meter').style.width = '0%';
      if (!silent) state('IDLE', 'Stream stopped');
    };
    const sampleDuration = () => sampleAudio ? sampleAudio.length/sampleRate : Math.min(10,sampleCount/sampleRate);
    const spectrumColumn = bytes => {
      const out=new Uint8Array(72),nyquist=sampleRate/2;
      for(let i=0;i<out.length;i++){const f0=80*Math.pow(100,i/out.length),f1=80*Math.pow(100,(i+1)/out.length);let a=Math.max(0,Math.floor(f0/nyquist*bytes.length)),b=Math.min(bytes.length,Math.max(a+1,Math.ceil(f1/nyquist*bytes.length))),peak=0;for(let j=a;j<b;j++)peak=Math.max(peak,bytes[j]);out[i]=peak;}
      return out;
    };
    const drawSpectrogram = () => {
      const canvas=$('sample-spectrogram'),ratio=window.devicePixelRatio||1,width=Math.round(Math.max(500,canvas.clientWidth)*ratio),height=Math.round(190*ratio);
      if(canvas.width!==width||canvas.height!==height){canvas.width=width;canvas.height=height;}const ctx=canvas.getContext('2d');ctx.fillStyle='#07101d';ctx.fillRect(0,0,width,height);
      if(spectrogram.length){const off=document.createElement('canvas');off.width=spectrogram.length;off.height=72;const ox=off.getContext('2d'),image=ox.createImageData(off.width,off.height);for(let x=0;x<off.width;x++)for(let y=0;y<72;y++){const t=spectrogram[x][71-y]/255,i=(y*off.width+x)*4;image.data[i]=Math.max(0,(t-.52)*510);image.data[i+1]=Math.max(8,(t-.08)*285);image.data[i+2]=Math.max(18,70+t*150);image.data[i+3]=255;}ox.putImageData(image,0,0);ctx.imageSmoothingEnabled=true;ctx.drawImage(off,0,0,width,height);}
      const duration=sampleDuration(),from=Math.min(duration,Number($('sample-from').value)||0),to=Math.min(duration,Number($('sample-to').value)||duration);if(duration){const x0=from/duration*width,x1=to/duration*width;ctx.fillStyle='#02071199';ctx.fillRect(0,0,x0,height);ctx.fillRect(x1,0,width-x1,height);ctx.strokeStyle='#72f3bd';ctx.lineWidth=2*ratio;ctx.strokeRect(x0,1,x1-x0,height-2);const px=Math.max(0,Math.min(width,playhead/duration*width));ctx.strokeStyle='#ffb45e';ctx.lineWidth=2*ratio;ctx.beginPath();ctx.moveTo(px,0);ctx.lineTo(px,height);ctx.stroke();ctx.fillStyle='#dbe9f8';ctx.font=`${11*ratio}px system-ui`;ctx.textAlign='center';for(let i=0;i<=4;i++){const x=i*width/4;ctx.fillText((duration*i/4).toFixed(1)+'s',x,height-7*ratio);}}
    };
    const setPlayhead = value => {playhead=Math.max(0,Math.min(sampleDuration(),value));metric('sample-playhead-label',playhead.toFixed(2)+' c');drawSpectrogram();};
    const stopPreview = (preserve=true) => {if(previewSource&&preserve)playhead=Math.min(previewEnd,previewOffset+(previewContext.currentTime-previewStartedAt));if(previewSource){previewSource.onended=null;try{previewSource.stop();}catch{}}previewSource=null;cancelAnimationFrame(previewFrame);$('sample-preview').textContent='▶ Play selection';setPlayhead(playhead);};
    const previewTick = () => {if(!previewSource)return;playhead=Math.min(previewEnd,previewOffset+(previewContext.currentTime-previewStartedAt));metric('sample-playhead-label',playhead.toFixed(2)+' c');drawSpectrogram();previewFrame=requestAnimationFrame(previewTick);};
    const playPreview = async startAt => {if(!sampleAudio?.length)return;if(previewSource)stopPreview(true);const from=Number($('sample-from').value),to=Number($('sample-to').value);let start=startAt??playhead,end=to;if(startAt!==undefined&&(start<from||start>=to)){start=Math.max(0,Math.min(sampleDuration()-.02,startAt));end=sampleDuration();}else if(start<from||start>=to-.03)start=from;previewContext||=new AudioContext({latencyHint:'interactive'});await previewContext.resume();if(!previewBuffer||previewBuffer.length!==sampleAudio.length||previewBuffer.sampleRate!==sampleRate){previewBuffer=previewContext.createBuffer(1,sampleAudio.length,sampleRate);previewBuffer.copyToChannel(sampleAudio,0);}const source=previewContext.createBufferSource();source.buffer=previewBuffer;source.connect(previewContext.destination);previewSource=source;previewOffset=start;previewEnd=end;previewStartedAt=previewContext.currentTime;setPlayhead(start);$('sample-preview').textContent='⏸ Pause';source.onended=()=>{if(previewSource!==source)return;previewSource=null;cancelAnimationFrame(previewFrame);setPlayhead(end);$('sample-preview').textContent='▶ Play selection';};source.start(0,start,Math.max(.02,end-start));previewTick();};
    const setSelection = (from,to) => {const duration=sampleDuration();from=Math.max(0,Math.min(duration,from));to=Math.max(0,Math.min(duration,to));if(from>to)[from,to]=[to,from];if(to-from<.2)to=Math.min(duration,from+.2);$('sample-from').value=from;$('sample-to').value=to;metric('sample-from-label',from.toFixed(2)+' c');metric('sample-to-label',to.toFixed(2)+' c');$('sample-selection-label').textContent=from.toFixed(2)+' — '+to.toFixed(2)+' c';$('sample-use-selection').disabled=to-from<1;if(playhead<from||playhead>to)setPlayhead(from);else drawSpectrogram();};
    const fftSpectrum = (audio,start,size=512) => {const re=new Float32Array(size),im=new Float32Array(size);for(let i=0;i<size;i++)re[i]=(audio[start+i]||0)*(.5-.5*Math.cos(2*Math.PI*i/(size-1)));for(let i=1,j=0;i<size;i++){let bit=size>>1;for(;j&bit;bit>>=1)j^=bit;j^=bit;if(i<j){[re[i],re[j]]=[re[j],re[i]];}}for(let len=2;len<=size;len<<=1){const angle=-2*Math.PI/len;for(let i=0;i<size;i+=len)for(let j=0;j<len/2;j++){const c=Math.cos(angle*j),s=Math.sin(angle*j),p=i+j,q=p+len/2,tr=re[q]*c-im[q]*s,ti=re[q]*s+im[q]*c;re[q]=re[p]-tr;im[q]=im[p]-ti;re[p]+=tr;im[p]+=ti;}}const bytes=new Uint8Array(size/2);for(let i=0;i<bytes.length;i++){const db=20*Math.log10(Math.hypot(re[i],im[i])/size+1e-6);bytes[i]=Math.max(0,Math.min(255,(db+80)/80*255));}return bytes;};
    const buildOfflineSpectrogram = audio => {spectrogram=[];const columns=Math.min(220,Math.max(24,Math.ceil(audio.length/sampleRate/.046)));for(let i=0;i<columns;i++){const start=Math.max(0,Math.min(audio.length-512,Math.floor(i*Math.max(0,audio.length-512)/Math.max(1,columns-1))));spectrogram.push(spectrumColumn(fftSpectrum(audio,start)));}};
    const finishSample = audio => {stopPreview(false);previewBuffer=null;playhead=0;sampleAudio=audio;const duration=sampleDuration();for(const id of ['sample-from','sample-to'])$(id).max=duration.toFixed(3);setSelection(0,duration);$('sample-time').textContent=duration.toFixed(1)+' / 10.0 s';$('sample-record').disabled=false;$('sample-stop').disabled=true;$('sample-preview').disabled=duration<.1;$('sample-analyze').disabled=duration<1;$('sample-use-selection').disabled=duration<1;$('sample-speaker-tracks').innerHTML='<div class="speaker-empty">Sample ready — run analysis to create Voice A / Voice B / Mixed lanes</div>';$('sample-status').textContent=duration?'Sample ready: click to listen, select a range, or run analysis.':'The recording is empty.';};
    const stopSample = () => {
      sampleProcessor?.disconnect(); sampleCapture?.getTracks().forEach(t=>t.stop()); sampleProcessor=sampleCapture=null;
      sampleContext?.close().catch(()=>{}); sampleContext=null;
      if(sampleChunks.length){const audio=new Float32Array(sampleCount);let offset=0;for(const chunk of sampleChunks){audio.set(chunk,offset);offset+=chunk.length;}finishSample(audio);}else finishSample(new Float32Array());
    };
    $('sample-record').onclick = async () => {
      try{
        if($('rt-start').disabled)stop(true); $('sample-record').disabled=true;$('sample-stop').disabled=false;$('sample-analyze').disabled=true;$('sample-use-selection').disabled=true;
        stopPreview(false);previewBuffer=null;$('sample-preview').disabled=true;sampleAudio=null;sampleChunks=[];sampleCount=0;spectrogram=[];$('sample-from').value=0;$('sample-to').value=0;$('sample-voices').replaceChildren();$('sample-transcript-wrap').hidden=true;$('sample-speaker-tracks').innerHTML='<div class="speaker-empty">Recording — lanes will appear after analysis</div>';
        $('sample-status').textContent='Requesting source…';const source=await acquireSource($('sample-source').value);sampleCapture=source.capture;
        sampleContext=new AudioContext({latencyHint:'interactive'});await sampleContext.resume();sampleRate=sampleContext.sampleRate;
        const media=sampleContext.createMediaStreamSource(source.input),silentGain=sampleContext.createGain();silentGain.gain.value=0;sampleAnalyser=sampleContext.createAnalyser();sampleAnalyser.fftSize=512;sampleAnalyser.smoothingTimeConstant=.62;
        sampleProcessor=sampleContext.createScriptProcessor(2048,1,1);media.connect(sampleAnalyser);sampleAnalyser.connect(sampleProcessor);sampleProcessor.connect(silentGain);silentGain.connect(sampleContext.destination);
        const freq=new Uint8Array(sampleAnalyser.frequencyBinCount);sampleProcessor.onaudioprocess=event=>{const input=new Float32Array(event.inputBuffer.getChannelData(0));sampleChunks.push(input);sampleCount+=input.length;const max=sampleRate*10;while(sampleCount>max&&sampleChunks.length>1)sampleCount-=sampleChunks.shift().length;sampleAnalyser.getByteFrequencyData(freq);spectrogram.push(spectrumColumn(freq));if(spectrogram.length>220)spectrogram.shift();const duration=sampleDuration();for(const id of ['sample-from','sample-to'])$(id).max=duration;$('sample-from').value=0;$('sample-to').value=duration;metric('sample-from-label','0.00 c');metric('sample-to-label',duration.toFixed(2)+' c');$('sample-selection-label').textContent='0.00 — '+duration.toFixed(2)+' c';drawSpectrogram();$('sample-time').textContent=duration.toFixed(1)+' / 10.0 c';};
        $('sample-status').textContent=source.label+' · capturing the latest 10 seconds…';
      }catch(e){$('sample-status').textContent=e.message;$('sample-record').disabled=false;$('sample-stop').disabled=true;}
    };
    $('sample-stop').onclick=stopSample;
    $('sample-file').onchange=async event=>{const file=event.target.files[0];if(!file)return;if($('sample-record').disabled)stopSample();$('sample-voices').replaceChildren();$('sample-transcript-wrap').hidden=true;$('sample-status').textContent='Decoding audio…';try{const decode=new AudioContext(),buffer=await decode.decodeAudioData(await file.arrayBuffer()),start=Math.max(0,buffer.length-buffer.sampleRate*10),audio=new Float32Array(buffer.length-start);for(let ch=0;ch<buffer.numberOfChannels;ch++){const data=buffer.getChannelData(ch);for(let i=start;i<buffer.length;i++)audio[i-start]+=data[i]/buffer.numberOfChannels;}sampleRate=buffer.sampleRate;await decode.close();sampleChunks=[];sampleCount=audio.length;buildOfflineSpectrogram(audio);finishSample(audio);$('sample-status').textContent=`${file.name} · latest ${sampleDuration().toFixed(1)} s ready for analysis.`;}catch(e){$('sample-status').textContent=e.message;}event.target.value='';};
    const updateTrim=event=>{let from=Number($('sample-from').value),to=Number($('sample-to').value);if(from>to-.2){if(event.target===$('sample-from'))from=Math.max(0,to-.2);else to=Math.min(Number($('sample-to').max),from+.2);}setSelection(from,to);};
    $('sample-from').oninput=updateTrim;$('sample-to').oninput=updateTrim;
    const canvas=$('sample-spectrogram'),pointerTime=event=>{const rect=canvas.getBoundingClientRect();return Math.max(0,Math.min(sampleDuration(),(event.clientX-rect.left)/rect.width*sampleDuration()));};canvas.onpointerdown=event=>{if(!sampleDuration())return;dragStart=pointerTime(event);dragOriginX=event.clientX;dragMoved=false;canvas.setPointerCapture(event.pointerId);};canvas.onpointermove=event=>{if(dragStart!==null&&Math.abs(event.clientX-dragOriginX)>5){dragMoved=true;stopPreview(true);setSelection(dragStart,pointerTime(event));}};canvas.onpointerup=event=>{if(dragStart===null)return;const at=pointerTime(event);if(dragMoved)setSelection(dragStart,at);else playPreview(at);dragStart=null;dragMoved=false;};
    const renderTracks=(voices,mixed,offset)=>{const host=$('sample-speaker-tracks'),duration=sampleDuration(),colors=['#65e6b4','#7aa7ff','#d58cff'];host.replaceChildren();const add=(name,segments,color)=>{if(!segments?.length)return;const row=document.createElement('div');row.className='speaker-row';const label=document.createElement('div');label.className='speaker-name';label.textContent=name;label.style.color=color;const lane=document.createElement('div');lane.className='speaker-lane';segments.forEach(segment=>{const block=document.createElement('button');block.className='speaker-segment';block.style.background=color;block.style.left=(offset+segment.start)/duration*100+'%';block.style.width=Math.max(.8,(segment.end-segment.start)/duration*100)+'%';block.title=`${name}: ${(offset+segment.start).toFixed(2)}—${(offset+segment.end).toFixed(2)} s`;block.onclick=()=>{setSelection(offset+segment.start,offset+segment.end);playPreview(offset+segment.start);};lane.append(block);});row.append(label,lane);host.append(row);};voices.forEach((voice,i)=>add(voice.name,voice.segments,colors[i%colors.length]));add('Mixed / uncertain',mixed,'#ff9f6e');if(!host.children.length)host.innerHTML='<div class="speaker-empty">No voice intervals were identified</div>';};
    $('sample-preview').onclick=()=>previewSource?stopPreview(true):playPreview();
    $('sample-min-voice').oninput=()=>metric('sample-min-voice-label',Number($('sample-min-voice').value).toFixed(1)+' c');$('sample-merge-gap').oninput=()=>metric('sample-merge-gap-label',Number($('sample-merge-gap').value).toFixed(2)+' c');
    $('sample-analyze').onclick=async()=>{
      if(!sampleAudio)return;const from=Math.floor(Number($('sample-from').value)*sampleRate),to=Math.ceil(Number($('sample-to').value)*sampleRate),slice=sampleAudio.slice(from,to),pcm=new Int16Array(slice.length);
      for(let i=0;i<slice.length;i++)pcm[i]=Math.max(-1,Math.min(1,slice[i]))*32767;$('sample-status').textContent='Analyzing voices…';$('sample-analyze').disabled=true;
      try{const response=await fetch('http://127.0.0.1:7861/sample/analyze',{method:'POST',headers:{'Content-Type':'application/octet-stream','X-Sample-Rate':String(sampleRate),'X-Speaker-Mode':$('sample-speaker-mode').value,'X-Min-Voice-Seconds':$('sample-min-voice').value,'X-Merge-Gap':$('sample-merge-gap').value},body:pcm.buffer});const data=await response.json();if(!response.ok)throw new Error(data.detail);renderVoices(data.voices);renderTracks(data.voices,data.mixed,from/sampleRate);$('sample-status').textContent=`Voices found: ${data.voices.length} · mixed/uncertain: ${data.mixed.length} · mode: ${data.settings.mode}. Click an interval to play it.`;}catch(e){$('sample-status').textContent=e.message;}finally{$('sample-analyze').disabled=false;}
    };
    const updateTextControls=()=>{$('text-generate').disabled=textGenerating||!textReferenceReady||!$('text-input').value.trim();$('text-ready').textContent=textReferenceReady?'Reference ready':'Reference required';$('text-ready').className='studio-pill '+(textReferenceReady?'ready':'waiting');};
    const refreshTextHealth=async()=>{try{const response=await fetch('http://127.0.0.1:7861/health'),data=await response.json();textReferenceReady=Boolean(data.ready);if(textReferenceReady&&$('text-status').textContent==='Prepare a voice in Sample Editor.')$('text-status').textContent='Voice reference ready — enter text.';updateTextControls();}catch{textReferenceReady=false;updateTextControls();}};
    const applyPrepared=(data,label)=>{$('sample-transcript').value=data.text;$('sample-transcript-wrap').hidden=false;$('sample-status').textContent=`${label} · ${data.seconds} s · ready in ${data.elapsed} s`;textReferenceReady=true;updateTextControls();$('text-status').textContent='Voice reference ready — enter text.';state('READY','Sample prepared — the stream can start');};
    const renderVoices=voices=>{const pool=$('sample-voices');pool.replaceChildren();voices.forEach(voice=>{const card=document.createElement('div');card.className='voice-card';const title=document.createElement('strong');title.textContent=voice.name;const detail=document.createElement('span');detail.textContent=`${voice.seconds} s · ${voice.profile} · ${voice.confidence}%`;const audio=document.createElement('audio');audio.controls=true;audio.src=voice.url;const button=document.createElement('button');button.className='rt-btn';button.textContent='Use entire voice';button.onclick=async()=>{button.disabled=true;$('sample-status').textContent='Running ASR and preparing the selected voice…';try{const r=await fetch(`http://127.0.0.1:7861/sample/select/${voice.id}`,{method:'POST'}),d=await r.json();if(!r.ok)throw new Error(d.detail);applyPrepared(d,voice.name+' selected');}catch(e){$('sample-status').textContent=e.message;}finally{button.disabled=false;}};card.append(title,detail,audio,button);pool.append(card);});};
    $('sample-use-selection').onclick=async()=>{if(!sampleAudio)return;const from=Math.floor(Number($('sample-from').value)*sampleRate),to=Math.ceil(Number($('sample-to').value)*sampleRate),slice=sampleAudio.slice(from,to),pcm=new Int16Array(slice.length);for(let i=0;i<slice.length;i++)pcm[i]=Math.max(-1,Math.min(1,slice[i]))*32767;$('sample-use-selection').disabled=true;$('sample-status').textContent='Preparing selected range…';try{const r=await fetch('http://127.0.0.1:7861/sample/select-region',{method:'POST',headers:{'Content-Type':'application/octet-stream','X-Sample-Rate':String(sampleRate)},body:pcm.buffer}),d=await r.json();if(!r.ok)throw new Error(d.detail);applyPrepared(d,'Range selected');}catch(e){$('sample-status').textContent=e.message;}finally{$('sample-use-selection').disabled=(to-from)/sampleRate<1;}};
    $('sample-save-text').onclick=async()=>{const response=await fetch('http://127.0.0.1:7861/sample/transcript',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({text:$('sample-transcript').value})});const data=await response.json();$('sample-status').textContent=response.ok?'Transcript applied.':data.detail;};
    $('text-input').oninput=()=>{metric('text-count',$('text-input').value.length+' / 2000');updateTextControls();};
    $('text-clear').onclick=()=>{$('text-input').value='';metric('text-count','0 / 2000');updateTextControls();$('text-input').focus();};
    $('text-generate').onclick=async()=>{const value=$('text-input').value.trim();if(!value||!textReferenceReady||textGenerating)return;textGenerating=true;updateTextControls();$('text-generate').textContent='Generating…';$('text-status').textContent='Synthesizing locally…';try{const response=await fetch('http://127.0.0.1:7861/text/synthesize',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({text:value})}),data=await response.json();if(!response.ok)throw new Error(data.detail);const host=$('text-history');host.querySelector('.text-empty')?.remove();const card=document.createElement('article');card.className='text-track';const copy=document.createElement('div');copy.className='text-track-copy';const title=document.createElement('strong');title.textContent=value.length>110?value.slice(0,110)+'…':value;const meta=document.createElement('span');meta.textContent=`${data.duration} s · created in ${data.elapsed} s`;copy.append(title,meta);const audio=document.createElement('audio');audio.controls=true;audio.src=data.url+'?t='+Date.now();if(audio.setSinkId&&$('rt-output').value)audio.setSinkId($('rt-output').value).catch(()=>{});const download=document.createElement('a');download.className='rt-btn text-download';download.textContent='Download WAV';download.href=data.url;download.download=data.filename;card.append(copy,audio,download);host.prepend(card);$('text-status').textContent=data.stats;audio.play().catch(()=>{});}catch(e){$('text-status').textContent=e.message;if(/reference/i.test(e.message)){textReferenceReady=false;}}finally{textGenerating=false;$('text-generate').textContent='Generate track';updateTextControls();}};
    channel && (channel.onmessage = e => { if (e.data === 'started') stop(true); });
    const refreshOutputs = async () => {
      const select = $('rt-output'), previous = select.value;
      const devices = (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === 'audiooutput');
      select.replaceChildren(...devices.map((d, i) => Object.assign(document.createElement('option'), {
        value: d.deviceId, textContent: d.label || `Device ${i + 1}`
      })));
      if (previous && [...select.options].some(o => o.value === previous)) select.value = previous;
      const blackhole = devices.find(d => /blackhole/i.test(d.label));
      metric('rt-device', blackhole ? 'BlackHole ready' : (devices.length ? `${devices.length} available` : 'system'));
      $('rt-routing').textContent = blackhole
        ? 'Virtual microphone available: select BlackHole as Output here and as the microphone in your call app.'
        : 'Install BlackHole 2ch for a virtual microphone, then refresh devices.';
    };
    $('rt-refresh-output').onclick = () => refreshOutputs().catch(e => state('ERROR', e.message));
    $('rt-output').onchange = async () => {
      if (!context?.setSinkId) return state('LIMITED', 'The browser is using the system output');
      try { await context.setSinkId($('rt-output').value); state('READY', `Output: ${$('rt-output').selectedOptions[0].textContent}`); }
      catch (e) { state('ERROR', `Output: ${e.message}`); }
    };
    $('rt-start').onclick = async () => {
      if(liveStarting||liveReady)return;
      const session=++liveSession;liveStarting=true;$('rt-start').disabled=true;$('rt-start').textContent='Connecting…';$('rt-stop').disabled=false;
      try {
        const inputMode=$('rt-input').value;
        const healthResponse=await fetch('http://127.0.0.1:7861/health'),health=await healthResponse.json();
        if(!health.ready)throw new Error('Prepare a sample in the editor or left panel first.');
        if(session!==liveSession)return;
        channel?.postMessage('started'); state('CONNECTING', inputMode==='system'?'Choose a screen or window and enable audio sharing…':'Requesting microphone…');
        let acquired;
        if(inputMode==='system'){
          acquired=await navigator.mediaDevices.getDisplayMedia({video:true,audio:true,systemAudio:'include'});
          const tracks=acquired.getAudioTracks();
          if(!tracks.length){acquired.getTracks().forEach(t=>t.stop());throw new Error('The browser did not provide system audio. Enable audio in the Share dialog.');}
          inputStream=new MediaStream(tracks); metric('rt-source','System audio');
        } else {
          acquired=await navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:true,noiseSuppression:true,autoGainControl:true}});
          inputStream=acquired; metric('rt-source','Microphone');
        }
        if(session!==liveSession){acquired.getTracks().forEach(t=>t.stop());return;}captureStream=acquired;
        context ||= new AudioContext({latencyHint:'interactive'}); await context.resume(); await refreshOutputs();
        if(session!==liveSession)return;
        socket = new WebSocket('ws://127.0.0.1:7861/ws'); socket.binaryType = 'arraybuffer';
        socket.onopen = () => {
          if(session!==liveSession)return socket.close();
          const pause = Number($('rt-pause').value) / 1000;
          socket.send(JSON.stringify({ref_id:'gradio',sample_rate:context.sampleRate,pause_seconds:pause}));
          const source = context.createMediaStreamSource(inputStream), silent = context.createGain(); silent.gain.value = 0;
          const audioReadyAt=performance.now()+350;
          processor = context.createScriptProcessor(2048,1,1); source.connect(processor); processor.connect(silent); silent.connect(context.destination);
          processor.onaudioprocess = event => {
            const input = event.inputBuffer.getChannelData(0);
            let sum = 0; for (let i=0;i<input.length;i++) sum += input[i]*input[i];
            const rms = Math.sqrt(sum/input.length), level = Math.min(100,rms*900);
            $('rt-meter').style.width = level+'%'; metric('rt-level', (20*Math.log10(Math.max(rms,1e-6))).toFixed(0)+' dB');
            if (performance.now()<audioReadyAt || !liveReady || busy || socket.readyState !== 1) return;
            const out = new Int16Array(input.length); for(let i=0;i<input.length;i++) out[i]=Math.max(-1,Math.min(1,input[i]))*32767;
            socket.send(out.buffer);
            if(rms>=0.012){speechRun+=input.length/context.sampleRate;if(!sawSpeech&&speechRun>=.18){phraseStarted=performance.now();sawSpeech=true;state('LISTENING','Stable speech detected…');}if(sawSpeech)silence=0;}
            else if(!sawSpeech)speechRun=0;
            else if(sawSpeech && (silence += input.length/context.sampleRate) >= pause){
              busy=true; metric('rt-vad',Math.round(silence*1000)+' ms'); state('PROCESSING','Transcribing phrase…');
            }
          };
          state('CONNECTING','WebSocket connected · waiting for server confirmation…');
        };
        socket.onmessage = event => {
          if(session!==liveSession)return;
          if(typeof event.data !== 'string'){ play(event.data); return; }
          const data=JSON.parse(event.data);
          if(data.type==='busy'){busy=true; metric('rt-phrase',data.input_seconds.toFixed(1)+' s'); state('PROCESSING','Transcribing phrase…');}
          if(data.type==='text'){ $('rt-text').textContent=data.text; metric('rt-asr',data.asr_ms+' ms'); state('SYNTHESIS','Synthesizing voice…'); }
          if(data.type==='audio_meta'){outputRate=data.sample_rate; metric('rt-ttfb',data.first_audio_ms+' ms'); state('PLAYING','Playing cloned voice');}
          if(data.type==='done'){
            const wait=Math.max(0,(nextPlayback-context.currentTime)*1000+80); clearTimeout(unlockTimer);
            unlockTimer=setTimeout(()=>{resetPhrase();metric('rt-queue','0.0 s');state('READY','Speak the next phrase');},wait);
          }
          if(data.type==='error'){resetPhrase();liveStarting=false;state('ERROR',data.message);}
          if(data.type==='status'){liveStarting=false;liveReady=true;$('rt-start').textContent='● Stream active';state('READY','Ready — speak; a pause will end the phrase');}
        };
        socket.onerror=()=>{if(session===liveSession)state('ERROR','WebSocket unavailable');}; socket.onclose=()=>{if(session===liveSession)stop(true);};
      } catch(e){if(session===liveSession){state('ERROR',e.message);stop(true);}}
    };
    $('rt-stop').onclick=()=>stop();$('sample-record').disabled=false;$('sample-record').textContent='● Record';$('sample-file').disabled=false;$('rt-start').disabled=false;$('rt-start').textContent='● Start';refreshTextHealth();textPoll=setInterval(refreshTextHealth,2000);window.addEventListener('beforeunload',()=>{clearInterval(textPoll);stop(true);stopPreview(false);previewContext?.close();},{once:true});
    return true;
  };
  const timer=setInterval(()=>{if(init())clearInterval(timer);},200); setTimeout(()=>clearInterval(timer),30000);
}
"""

LIVE_CSS = """
#rt-shell,.sample-lab,.studio-section,.studio-hero{max-width:1100px;margin-left:auto;margin-right:auto}
.rt-panel,.sample-lab,.studio-section{background:linear-gradient(145deg,#111827,#0b1220);border:1px solid #263244;border-radius:22px;padding:22px;color:#e5edf7;box-shadow:0 18px 60px #0003}
.studio-hero{display:flex;justify-content:space-between;align-items:flex-end;gap:24px;margin-top:8px;margin-bottom:20px;padding:28px 30px;border-radius:24px;background:radial-gradient(circle at 85% 15%,#5b5cf044,transparent 35%),linear-gradient(135deg,#111a2b,#0a1220);border:1px solid #283750;color:#eef5ff;box-shadow:0 18px 65px #0003}.studio-hero h2{font-size:36px;line-height:1.05;margin:6px 0 9px;letter-spacing:-.035em;color:#f4f8ff!important}.studio-hero p{margin:0;color:#9eacc0;font-size:15px}.studio-eyebrow,.studio-step{font:750 11px/1.2 monospace;letter-spacing:.14em;color:#7aa7ff}.studio-badges{display:flex;gap:7px;flex-wrap:wrap;justify-content:flex-end}.studio-badges span,.studio-pill{border:1px solid #344760;border-radius:99px;padding:7px 10px;background:#101b2c;color:#b9c8da;font:700 10px/1 monospace;letter-spacing:.06em}.studio-pill.ready{border-color:#2d7f64;background:#0d2b24;color:#72f3bd}.studio-pill.waiting{color:#9aaabd}
.sample-lab{margin-bottom:20px}.rt-top,.sample-editor-head{display:flex;justify-content:space-between;gap:20px;align-items:center}.rt-title{font-size:25px;font-weight:700;color:#f4f8ff}.rt-sub{color:#91a0b5;margin-top:3px}.rt-actions,.sample-actions{display:flex;gap:9px;flex-wrap:wrap}.rt-btn{border:1px solid #3b4b63;border-radius:12px;padding:10px 17px;background:#182235;color:#eaf2ff;font-weight:650;cursor:pointer}.rt-btn.primary{background:#5b5cf0;border-color:#7677ff}.rt-btn:disabled{opacity:.4}.rt-state{font:700 12px/1 monospace;letter-spacing:.08em;color:#8ea2bd}
.studio-section{margin-bottom:20px}.studio-section-head{display:flex;align-items:flex-start;justify-content:space-between;gap:20px}.studio-step{margin-bottom:7px}.studio-textarea{display:block;width:100%;min-height:132px;resize:vertical;margin-top:17px;padding:16px 17px;border:1px solid #334760;border-radius:14px;background:#091320;color:#f2f7ff;font:16px/1.55 system-ui;outline:none;transition:border-color .18s,box-shadow .18s}.studio-textarea:focus{border-color:#7475ff;box-shadow:0 0 0 3px #5b5cf025}.text-toolbar{display:flex;align-items:center;justify-content:space-between;gap:16px;margin-top:11px}.text-toolbar>span{color:#77899f;font:11px/1 monospace}.text-history{display:flex;flex-direction:column;gap:9px;margin-top:15px}.text-empty{padding:18px;border:1px dashed #2b3d54;border-radius:12px;color:#71839a;text-align:center;font-size:12px}.text-track{display:grid;grid-template-columns:minmax(180px,1fr) minmax(280px,1.3fr) auto;align-items:center;gap:14px;padding:12px 13px;border:1px solid #2b3e56;border-radius:13px;background:#0b1625}.text-track-copy{display:flex;min-width:0;flex-direction:column;gap:5px}.text-track-copy strong{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:#eaf2ff;font-size:13px}.text-track-copy span{color:#8193aa;font-size:11px}.text-track audio{width:100%;height:36px}.text-download{text-decoration:none;text-align:center;white-space:nowrap}
.rt-grid{display:grid;grid-template-columns:1.5fr 1fr;gap:14px;margin-top:18px}.rt-card{background:#101a29;border:1px solid #263244;border-radius:16px;padding:16px;color:#e5edf7}.rt-label{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:#8ea2bd}.rt-status{font-size:17px;margin-top:8px;color:#f4f8ff}.rt-meter-bg{height:14px;background:#202d40;border-radius:99px;overflow:hidden;margin-top:16px}.rt-meter{height:100%;width:0;background:linear-gradient(90deg,#29d391,#d9e44c,#ff6b6b);transition:width .06s}.rt-metrics{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-top:14px}.rt-metric{background:#0a1320;border-radius:11px;padding:10px}.rt-value{font-size:17px;font-weight:700;margin-top:5px;color:#f4f8ff}.rt-transcript{min-height:72px;font-size:18px;line-height:1.45;margin-top:9px;color:#f4f8ff}.rt-control{width:100%;margin:7px 0 12px;background:#0a1320;color:#e5edf7;border:1px solid #33445d;border-radius:10px;padding:9px}#rt-source,#rt-level{color:#c9d6e8}
.sample-toolbar{display:flex;gap:9px;align-items:center;flex-wrap:wrap;margin-top:16px}.sample-toolbar .rt-control{width:auto;min-width:220px;margin:0}.sample-file-label{position:relative;overflow:hidden}.sample-file-label:has(input:disabled){opacity:.4}.sample-file-label input{position:absolute;inset:0;opacity:0;cursor:pointer}.sample-canvas-wrap{position:relative;margin:15px 0 8px;padding-left:42px}.sample-spectrogram{display:block;width:100%;height:190px;border:1px solid #2e4562;border-radius:13px;background:#07101d;cursor:crosshair;touch-action:none}.sample-frequency{position:absolute;left:0;top:3px;bottom:3px;width:38px;display:flex;flex-direction:column;justify-content:space-between;color:#8fa2ba;font:10px/1 monospace;text-align:right}.sample-selection-info{display:flex;gap:13px;align-items:center;flex-wrap:wrap;font-size:12px}.sample-selection-info span{color:#9cafc5}.sample-selection-info strong{color:#72f3bd;font:700 13px/1 monospace}#sample-playhead-label{color:#ffb45e}.sample-trim{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin:12px 0}.sample-trim label{display:grid;grid-template-columns:auto 1fr auto;gap:9px;align-items:center;color:#aebdd0;font-size:12px}.sample-trim input{width:100%;accent-color:#65e6b4}.speaker-settings{margin:10px 0;border:1px solid #26394f;border-radius:10px;padding:9px 12px;background:#0b1523}.speaker-settings summary{cursor:pointer;color:#9fb0c5;font-size:12px;font-weight:650}.speaker-settings-grid{display:grid;grid-template-columns:1.25fr 1fr 1fr;gap:14px;margin-top:12px}.speaker-settings-grid label{display:grid;grid-template-columns:1fr auto;gap:7px;align-items:center;color:#9fb0c5;font-size:11px}.speaker-settings-grid label:first-child{display:block}.speaker-settings-grid .rt-control{margin:6px 0 0}.speaker-settings-grid input{grid-column:1;width:100%;accent-color:#7aa7ff}.speaker-settings-grid span{font:700 11px/1 monospace;color:#d7e1ee}
.speaker-tracks{display:flex;flex-direction:column;gap:7px;margin:14px 0;padding:10px;background:#091320;border:1px solid #22354b;border-radius:12px}.speaker-empty{color:#6f829a;font-size:12px;padding:5px}.speaker-row{display:grid;grid-template-columns:118px 1fr;gap:10px;align-items:center}.speaker-name{font:700 11px/1.2 monospace;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.speaker-lane{position:relative;height:23px;border-radius:6px;background:repeating-linear-gradient(90deg,#132033 0,#132033 calc(10% - 1px),#26374c calc(10% - 1px),#26374c 10%);overflow:hidden}.speaker-segment{position:absolute;top:3px;height:17px;min-width:4px;border:0;border-radius:4px;opacity:.85;cursor:pointer;transition:opacity .15s,transform .15s}.speaker-segment:hover{opacity:1;transform:scaleY(1.14)}
.voice-pool{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:10px;margin-top:12px}.voice-card{display:flex;flex-direction:column;gap:8px;background:#101a29;border:1px solid #30445f;border-radius:13px;padding:12px}.voice-card strong{color:#f4f8ff}.voice-card span{min-height:32px;color:#93a5bb;font-size:12px}.voice-card audio{width:100%;height:36px}#sample-transcript-wrap{margin-top:14px}#sample-transcript-wrap[hidden]{display:none}
@media(max-width:760px){.studio-hero,.rt-top,.sample-editor-head,.studio-section-head{align-items:flex-start;flex-direction:column}.studio-hero h2{font-size:30px}.studio-badges{justify-content:flex-start}.rt-grid,.sample-trim,.speaker-settings-grid,.text-track{grid-template-columns:1fr}.rt-metrics{grid-template-columns:repeat(2,1fr)}.speaker-row{grid-template-columns:90px 1fr}.text-toolbar{align-items:flex-start;flex-direction:column}.text-track audio{width:100%}}
"""


def _load(model_id: str):
    global MODEL, MODEL_ID
    if MODEL is not None and MODEL_ID == model_id:
        return MODEL

    MODEL = None
    MODEL_ID = None
    gc.collect()
    mx.clear_cache()
    MODEL = load_model(model_id)
    MODEL_ID = model_id
    return MODEL


def _load_stt(model_id: str):
    global STT_MODEL, STT_MODEL_ID
    if STT_MODEL is not None and STT_MODEL_ID == model_id:
        return STT_MODEL

    STT_MODEL = None
    STT_MODEL_ID = None
    gc.collect()
    mx.clear_cache()
    STT_MODEL = load_stt(model_id)
    STT_MODEL_ID = model_id
    return STT_MODEL


def _tts_token_budget(model, text: str) -> int:
    """Bound runaway no-EOS generations while leaving generous speech headroom."""
    try:
        text_tokens = len(model.tokenizer.encode(text))
    except Exception:
        text_tokens = max(1, len(text) // 4)
    return min(2048, max(75, text_tokens * 6))


def _acquire_process_lock(path: Path):
    """Hold an advisory lock for the lifetime of this Python process."""
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open("a+")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        raise RuntimeError(f"Voice clone Studio is already running (lock: {path}).")
    handle.seek(0)
    handle.truncate()
    handle.write(f"{os.getpid()}\n")
    handle.flush()
    return handle


def _apply_emotion_fx(
    path: Path,
    emotion: str,
    strength: float,
    sample_rate: int,
    pace: float = 1.0,
    pitch_shift: float = 0.0,
) -> None:
    """Shape the delivery of a finished take: an emotion setting, plus an explicit pace and
    pitch offset. All of it is post-processing, so it costs one ffmpeg pass and no GPU."""
    emotion = _emotion_key(emotion)
    settings = EMOTION_FX[emotion]
    strength = min(max(float(strength), 0.0), 1.0)
    pace = min(max(float(pace), 0.6), 1.6)
    pitch_shift = min(max(float(pitch_shift), -6.0), 6.0)
    neutral = emotion == "As in the reference" or strength == 0.0
    if neutral and abs(pace - 1.0) < 0.005 and abs(pitch_shift) < 0.01:
        return

    if neutral:
        settings = {"tempo": 1.0, "pitch": 0.0, "gain": 0.0}
    tempo = (1.0 + (settings["tempo"] - 1.0) * strength) * pace
    semitones = settings["pitch"] * strength + pitch_shift
    pitch_ratio = 2 ** (semitones / 12.0)
    gain = settings["gain"] * strength
    # asetrate moves pitch and speed together; atempo puts the speed back. Keep the product
    # inside the range one atempo filter accepts.
    tempo = min(2.0 * pitch_ratio, max(0.5 * pitch_ratio, tempo))

    filters = [
        f"asetrate={sample_rate * pitch_ratio:.4f}",
        f"aresample={sample_rate}",
        f"atempo={tempo / pitch_ratio:.6f}",
    ]
    if settings.get("compress"):
        filters.append("acompressor=threshold=-18dB:ratio=3:attack=5:release=80")
    if settings.get("tremolo"):
        filters.append(f"tremolo=f=8:d={0.04 * strength:.4f}")
    filters.append(f"volume={gain:.3f}dB")

    processed = path.with_name(f"{path.stem}.fx.wav")
    try:
        subprocess.run(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-i",
                str(path),
                "-af",
                ",".join(filters),
                "-ar",
                str(sample_rate),
                str(processed),
            ],
            check=True,
        )
        processed.replace(path)
    finally:
        processed.unlink(missing_ok=True)


def _save(
    results,
    prefix: str,
    emotion: str = "As in the reference",
    emotion_strength: float = 0.0,
    pace: float = 1.0,
    pitch_shift: float = 0.0,
) -> tuple[str, str]:
    results = list(results)
    if not results:
        raise gr.Error("The model returned no audio.")

    chunks = [np.asarray(result.audio, dtype=np.float32).reshape(-1) for result in results]
    audio = np.concatenate(chunks)
    sample_rate = int(results[0].sample_rate)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    path = OUTPUT_DIR / f"{prefix}-{stamp}.wav"
    sf.write(path, audio, sample_rate)
    _apply_emotion_fx(path, emotion, emotion_strength, sample_rate, pace, pitch_shift)

    processing = sum(float(result.processing_time_seconds) for result in results)
    duration = sf.info(path).duration
    rtf = duration / processing if processing else 0.0
    peak = max(float(result.peak_memory_usage) for result in results)
    emotion_note = (
        "inherited from reference"
        if _emotion_key(emotion) == "As in the reference" or emotion_strength == 0
        else f"{_emotion_key(emotion).lower()}, post-processing {emotion_strength:.0%}"
    )
    if abs(pace - 1.0) >= 0.005 or abs(pitch_shift) >= 0.01:
        emotion_note += f" · pace {pace:.2f}× · pitch {pitch_shift:+.1f} st"
    stats = (
        f"Audio: {duration:.2f} s · generation: {processing:.2f} s · "
        f"speed: {rtf:.2f}× realtime · MLX peak: {peak:.2f} GB · "
        f"emotion: {emotion_note}"
    )
    return str(path), stats


def design_voice(
    text: str,
    instruct: str,
    temperature: float,
    top_p: float,
    top_k: int,
    repetition_penalty: float,
    seed: int,
):
    if not text.strip():
        raise gr.Error("Enter text to synthesize.")
    if not instruct.strip():
        raise gr.Error("Describe the voice and delivery.")

    with MODEL_LOCK:
        mx.random.seed(int(seed))
        model = _load(DESIGN_MODEL)
        return _save(
            model.generate(
                text=text.strip(),
                instruct=instruct.strip(),
                lang_code=_text_language(text),
                max_tokens=_tts_token_budget(model, text),
                temperature=float(temperature),
                top_p=float(top_p),
                top_k=int(top_k),
                repetition_penalty=float(repetition_penalty),
                verbose=True,
            ),
            "design",
        )


def transcribe_reference(ref_audio: str | None) -> tuple[str, str]:
    if not ref_audio:
        raise gr.Error("Upload or record a reference first.")

    with MODEL_LOCK:
        model = _load_stt(ASR_MODEL)
        result = model.generate(ref_audio, language=None)
        text = result.text.strip()
        if not text:
            raise gr.Error("STT returned no text. Try a cleaner reference.")
        return text, f"Transcribed locally with Qwen3-ASR: {result.total_time:.2f} s"


def clone_voice(
    ref_audio: str | None,
    ref_text: str,
    auto_transcribe: bool,
    target_text: str,
    emotion: str,
    emotion_strength: float,
    temperature: float,
    top_p: float,
    top_k: int,
    repetition_penalty: float,
    seed: int,
):
    if not ref_audio:
        raise gr.Error("Upload a voice reference.")
    if not target_text.strip():
        raise gr.Error("Enter new text.")

    with MODEL_LOCK:
        generated_transcript = False
        if not ref_text.strip():
            if not auto_transcribe:
                raise gr.Error("Enter a transcript or enable automatic transcription.")
            model = _load_stt(ASR_MODEL)
            result = model.generate(ref_audio, language=None)
            ref_text = result.text.strip()
            generated_transcript = True
            if not ref_text:
                raise gr.Error("STT returned no text. Try a cleaner reference.")

        mx.random.seed(int(seed))
        model = _load(CLONE_MODEL)
        path, stats = _save(
            model.generate(
                text=target_text.strip(),
                ref_audio=ref_audio,
                ref_text=ref_text.strip(),
                lang_code=_text_language(target_text),
                max_tokens=_tts_token_budget(model, target_text),
                temperature=float(temperature),
                top_p=float(top_p),
                top_k=int(top_k),
                repetition_penalty=float(repetition_penalty),
                verbose=True,
            ),
            "clone",
            emotion,
            emotion_strength,
        )
        if generated_transcript:
            stats += " · transcript: automatic"
        return path, stats, ref_text


def prepare_live() -> str:
    """Load both models once so the first push-to-talk request is not cold."""
    with MODEL_LOCK:
        _load_stt(ASR_MODEL)
        _load(CLONE_MODEL)
    return "Models loaded. You can record a phrase."


def prepare_websocket_reference(ref_audio: str | None) -> tuple[str, str]:
    if not ref_audio:
        raise gr.Error("Upload a voice sample.")
    started = time.perf_counter()
    with MODEL_LOCK:
        result = _load_stt(ASR_MODEL).generate(ref_audio, language=None)
        text = result.text.strip()
        if not text:
            raise gr.Error("STT returned no text. Try a cleaner sample.")
        _load(CLONE_MODEL)
        _set_reference(ref_audio, text, _normalize_language(getattr(result, "language", None)))
    return text, f"Ready in {time.perf_counter() - started:.2f} s · ASR and TTS warmed up."


def update_websocket_reference_text(text: str) -> str:
    _set_reference(WEBSOCKET_REFERENCE_AUDIO, text)
    return "The sample transcript was updated for the real-time stream."


def live_transform(
    ref_audio: str | None,
    ref_text: str,
    mic_audio: str | None,
    seed: int,
) -> tuple[str, str, str]:
    if not ref_audio:
        raise gr.Error("Upload a voice-cloning sample.")
    if not ref_text.strip():
        raise gr.Error("A transcript of the voice sample is required.")
    if not mic_audio:
        raise gr.Error("Record a phrase with the microphone.")

    recording_debug = inspect_recording(mic_audio)
    audio, _ = sf.read(mic_audio, always_2d=False)
    samples = np.asarray(audio, dtype=np.float32).reshape(-1)
    rms = float(np.sqrt(np.mean(samples * samples))) if len(samples) else 0.0
    active_ratio = float(np.mean(np.abs(samples) >= 0.002)) if len(samples) else 0.0
    if rms < MIN_RECORDING_RMS or active_ratio < MIN_ACTIVE_AUDIO_RATIO:
        raise gr.Error(
            "The recording contains almost no speech, so ASR may hallucinate a short phrase. "
            f"{recording_debug}"
        )

    started = time.perf_counter()
    with MODEL_LOCK:
        stt = _load_stt(ASR_MODEL)
        recognized = stt.generate(mic_audio, language=None)
        text = recognized.text.strip()
        stt_seconds = time.perf_counter() - started
        if not text:
            raise gr.Error("The phrase could not be recognized. Record it again.")

        mx.random.seed(int(seed))
        tts = _load(CLONE_MODEL)
        path, tts_stats = _save(
            tts.generate(
                text=text,
                ref_audio=ref_audio,
                ref_text=ref_text.strip(),
                lang_code=_text_language(text, getattr(recognized, "language", None)),
                max_tokens=_tts_token_budget(tts, text),
                temperature=0.7,
                top_p=0.9,
                top_k=30,
                repetition_penalty=1.5,
                verbose=True,
            ),
            "live",
        )
    total = time.perf_counter() - started
    return text, path, f"STT: {stt_seconds:.2f} s · total: {total:.2f} s · {tts_stats}"


def inspect_recording(audio_path: str | None) -> str:
    """Expose browser-capture facts in the UI before sending audio to ASR."""
    if not audio_path:
        return "No recording yet. Press Record, speak, then press Stop."
    try:
        audio, sample_rate = sf.read(audio_path, always_2d=False)
        samples = np.asarray(audio, dtype=np.float32).reshape(-1)
        if not len(samples):
            return "The WAV contains zero samples."
        rms = float(np.sqrt(np.mean(samples * samples)))
        peak = float(np.max(np.abs(samples)))
        active = float(np.mean(np.abs(samples) >= 0.002)) * 100
        seconds = len(samples) / sample_rate
        size_kb = Path(audio_path).stat().st_size / 1024
        verdict = (
            "speech is probably present"
            if active / 100 >= MIN_ACTIVE_AUDIO_RATIO and rms >= MIN_RECORDING_RMS
            else "near silence or a signal that is too weak"
        )
        return (
            f"Input WAV: {seconds:.2f} s · {sample_rate} Hz · {size_kb:.0f} KB · "
            f"RMS {rms:.4f} · peak {peak:.3f} · active audio {active:.1f}% — {verdict}."
        )
    except Exception as error:
        return f"Could not read the recording: {error}"


def _pitch_hz(frame: np.ndarray, sample_rate: int) -> float:
    """Cheap autocorrelation pitch estimate used only as a pool hint."""
    frame = frame - float(np.mean(frame))
    if not len(frame) or float(np.sqrt(np.mean(frame * frame))) < 0.004:
        return 0.0
    size = 1 << (len(frame) * 2 - 1).bit_length()
    spectrum = np.fft.rfft(frame, size)
    correlation = np.fft.irfft(spectrum * np.conj(spectrum))[: len(frame)]
    lo, hi = max(1, sample_rate // 320), min(len(frame), sample_rate // 75)
    if hi <= lo:
        return 0.0
    lag = lo + int(np.argmax(correlation[lo:hi]))
    return sample_rate / lag if correlation[lag] > correlation[0] * 0.12 else 0.0


def _kmeans(features: np.ndarray, count: int) -> tuple[np.ndarray, float]:
    centers = [features[0]]
    for _ in range(1, count):
        distance = np.min(
            np.stack([np.sum((features - center) ** 2, axis=1) for center in centers]),
            axis=0,
        )
        centers.append(features[int(np.argmax(distance))])
    centers = np.asarray(centers)
    labels = np.zeros(len(features), dtype=int)
    for iteration in range(20):
        distances = np.stack(
            [np.sum((features - center) ** 2, axis=1) for center in centers], axis=1
        )
        updated = np.argmin(distances, axis=1)
        if np.array_equal(updated, labels) and iteration:
            break
        labels = updated
        for index in range(count):
            members = features[labels == index]
            if len(members):
                centers[index] = members.mean(axis=0)
    if count == 1:
        return labels, 0.0
    scores = []
    for index, feature in enumerate(features):
        own = features[labels == labels[index]]
        a = float(np.mean(np.linalg.norm(own - feature, axis=1))) if len(own) > 1 else 0.0
        other = [
            float(np.mean(np.linalg.norm(features[labels == group] - feature, axis=1)))
            for group in range(count)
            if group != labels[index] and np.any(labels == group)
        ]
        b = min(other) if other else 0.0
        scores.append((b - a) / max(a, b, 1e-6))
    return labels, float(np.mean(scores))


def _speaker_segments(
    labels: np.ndarray,
    spans: list[tuple[int, int]],
    speaker: int,
    sample_rate: int,
    merge_gap: float,
) -> list[dict]:
    """Turn frame labels into compact timeline ranges."""
    ranges: list[list[int]] = []
    join_gap = int(sample_rate * merge_gap)
    for (start, end), label in zip(spans, labels):
        if label != speaker:
            continue
        if ranges and start <= ranges[-1][1] + join_gap:
            ranges[-1][1] = end
        else:
            ranges.append([start, end])
    return [
        {"start": round(start / sample_rate, 2), "end": round(end / sample_rate, 2)}
        for start, end in ranges
        if end - start >= sample_rate * 0.16
    ]


def analyze_speaker_pool(
    audio: np.ndarray,
    sample_rate: int,
    mode: str = "conservative",
    min_voice_seconds: float = 0.9,
    merge_gap: float = 0.55,
) -> dict:
    """Fast heuristic diarization for a short audition buffer."""
    settings = {
        "conservative": {"score": 0.52, "pitch_gap": 70, "speakers": 2, "mixed": 0.90},
        "balanced": {"score": 0.43, "pitch_gap": 50, "speakers": 3, "mixed": 0.84},
        "sensitive": {"score": 0.25, "pitch_gap": 20, "speakers": 3, "mixed": 0.78},
    }
    mode = mode if mode in settings else "conservative"
    config = settings[mode]
    min_voice_seconds = min(max(float(min_voice_seconds), 0.5), 2.5)
    merge_gap = min(max(float(merge_gap), 0.1), 1.5)
    audio = np.asarray(audio, dtype=np.float32).reshape(-1)
    if len(audio) < sample_rate:
        raise ValueError("At least one second of audio is required.")
    window, hop = int(sample_rate * 0.64), int(sample_rate * 0.32)
    frames, spans, pitches = [], [], []
    for start in range(0, max(1, len(audio) - window + 1), hop):
        frame = audio[start : start + window]
        rms = float(np.sqrt(np.mean(frame * frame)))
        if rms < 0.006:
            continue
        tapered = frame * np.hanning(len(frame))
        spectrum = np.abs(np.fft.rfft(tapered, n=4096)) ** 2 + 1e-10
        bands = np.array([np.log(part.mean()) for part in np.array_split(spectrum, 14)])
        bands -= bands.mean()
        pitch = _pitch_hz(frame, sample_rate)
        zcr = float(np.mean(np.signbit(frame[1:]) != np.signbit(frame[:-1])))
        # Loudness is deliberately excluded: it changes with emotion and mic
        # distance but should not create a new speaker identity.
        frames.append(np.r_[bands, np.log(max(pitch, 1.0)), zcr])
        spans.append((start, min(start + hop, len(audio))))
        pitches.append(pitch)
    if not frames:
        raise ValueError("No speech was found because the signal is too quiet.")
    features = np.asarray(frames)
    voiced_pitch = np.asarray(pitches) > 0
    if np.any(voiced_pitch):
        features[~voiced_pitch, -2] = float(np.median(features[voiced_pitch, -2]))
    features = (features - features.mean(axis=0)) / (features.std(axis=0) + 1e-5)
    # Pitch is more stable for this lightweight short-window heuristic than
    # phoneme-dependent spectral detail. Sensitive modes can then separate a
    # clearly low/high pair without using loudness as identity evidence.
    features[:, -2] *= {"conservative": 1.25, "balanced": 1.8, "sensitive": 2.6}[mode]
    features[:, -1] *= 0.45
    best_labels, best_score = np.zeros(len(features), dtype=int), 0.0
    minimum_frames = max(2, int(np.ceil(min_voice_seconds / (hop / sample_rate))))
    for count in range(2, min(config["speakers"], len(features) // minimum_frames) + 1):
        labels, score = _kmeans(features, count)
        if score > best_score and all(np.sum(labels == i) >= minimum_frames for i in range(count)):
            best_labels, best_score = labels, score
    if best_score < config["score"]:
        best_labels, best_score = np.zeros(len(features), dtype=int), 0.0
    else:
        smoothed = best_labels.copy()
        for index in range(1, len(best_labels) - 1):
            neighborhood = best_labels[index - 1 : index + 2]
            values, counts = np.unique(neighborhood, return_counts=True)
            smoothed[index] = values[int(np.argmax(counts))]
        best_labels = smoothed
        # A single expressive speaker often forms separate spectral clusters.
        # Merge them unless their median pitch differs enough to be useful as
        # a practical short-sample voice choice.
        cluster_pitch = []
        for speaker in sorted(set(best_labels.tolist())):
            voiced = [p for p, label in zip(pitches, best_labels) if label == speaker and p > 0]
            if voiced:
                cluster_pitch.append(float(np.median(voiced)))
        clear_low_high_split = min(cluster_pitch, default=0) < 155 < 185 < max(cluster_pitch, default=0)
        pitch_separation = max(cluster_pitch, default=0) - min(cluster_pitch, default=0)
        if (
            len(cluster_pitch) < 2
            or pitch_separation < config["pitch_gap"]
            or (mode == "conservative" and not clear_low_high_split)
        ):
            best_labels, best_score = np.zeros(len(features), dtype=int), 0.0
    timeline_labels = best_labels.copy()
    if len(set(best_labels.tolist())) > 1:
        centers = np.stack(
            [features[best_labels == speaker].mean(axis=0) for speaker in sorted(set(best_labels.tolist()))]
        )
        distances = np.linalg.norm(features[:, None, :] - centers[None, :, :], axis=2)
        ordered = np.sort(distances, axis=1)
        ambiguous = ordered[:, 0] / np.maximum(ordered[:, 1], 1e-6) > config["mixed"]
        # A lone ambiguous frame is normally a transition, not overlapping speech.
        confirmed = ambiguous & (np.r_[False, ambiguous[:-1]] | np.r_[ambiguous[1:], False])
        timeline_labels[confirmed] = -1
    results = []
    for speaker in sorted(set(best_labels.tolist())):
        parts = [audio[start:end] for (start, end), label in zip(spans, timeline_labels) if label == speaker]
        joined = np.concatenate(parts) if parts else np.array([], dtype=np.float32)
        if len(joined) < sample_rate * min_voice_seconds:
            continue
        speaker_pitches = [p for p, label in zip(pitches, best_labels) if label == speaker and p > 0]
        pitch = float(np.median(speaker_pitches)) if speaker_pitches else 0.0
        if pitch and pitch < 155:
            profile = "low pitch · likely male range"
        elif pitch > 185:
            profile = "high pitch · likely female range"
        else:
            profile = "mid pitch · gender undetermined"
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        path = OUTPUT_DIR / f"speaker-{speaker + 1}-{stamp}.wav"
        sf.write(path, joined, sample_rate)
        results.append({
            "path": str(path), "seconds": round(len(joined) / sample_rate, 2),
            "pitch_hz": round(pitch) if pitch else None, "profile": profile,
            "confidence": round((best_score if len(set(best_labels)) > 1 else 0.55) * 100),
            "segments": _speaker_segments(timeline_labels, spans, speaker, sample_rate, merge_gap),
        })
    if not results:
        raise ValueError("No sufficiently long voice segment could be isolated.")
    return {
        "voices": results,
        "mixed": _speaker_segments(timeline_labels, spans, -1, sample_rate, merge_gap),
        "duration": round(len(audio) / sample_rate, 2),
        "settings": {
            "mode": mode,
            "min_voice_seconds": min_voice_seconds,
            "merge_gap": merge_gap,
        },
    }


class LiveTelemetry:
    """Event-loop-owned accounting; packet count is never presented as phrase count."""

    def __init__(self, sample_rate: int):
        self.sample_rate = sample_rate
        self.pending = deque()
        self.pending_bytes = 0
        self.phase = "listening"
        self.phrase_id = 0
        self.phrase_end_received_at = None
        self.last_speed = None

    def received(self, pcm: bytes, now: float) -> None:
        self.pending.append(now)
        self.pending_bytes += len(pcm)

    def consumed(self, pcm: bytes) -> None:
        self.pending.popleft()
        self.pending_bytes -= len(pcm)

    def snapshot(self, now: float) -> dict:
        # Age since the end of the phrase currently being generated; otherwise
        # age of the oldest unconsumed packet. Endpoint wait is shown separately.
        origin = self.phrase_end_received_at
        if self.pending:
            origin = min(origin, self.pending[0]) if origin is not None else self.pending[0]
        return {
            "type": "telemetry", "phase": self.phase,
            "input_packets": len(self.pending),
            "input_buffer_seconds": round(self.pending_bytes / 2 / self.sample_rate, 3),
            "generation_lag_seconds": round(max(0, now - origin), 3) if origin is not None else 0,
            "active_phrase": self.phrase_id if self.phrase_end_received_at is not None else None,
            "synthesis_speed": self.last_speed,
        }


class PhraseBuffer:
    """Server-side VAD for raw PCM chunks from the browser WebSocket client."""

    def __init__(
        self, sample_rate: int, pause_seconds: float = LIVE_PAUSE_SECONDS,
        endpoint_mode: str = "pause",
    ):
        self.sample_rate = sample_rate
        self.pause_seconds = pause_seconds
        self.endpoint_mode = endpoint_mode
        self.chunks: list[np.ndarray] = []
        self.pre_roll: list[np.ndarray] = []
        self.silence_seconds = 0.0
        self.voiced_seconds = 0.0
        self.noise_rms = 0.0018
        self.last_rms = 0.0
        self.threshold = LIVE_VAD_RMS
        self.last_probe_samples = 0

    def reset(self) -> None:
        self.chunks = []
        self.pre_roll = []
        self.silence_seconds = 0.0
        self.voiced_seconds = 0.0
        self.last_probe_samples = 0

    def _candidate(self, trim_seconds: float = 0.0) -> np.ndarray:
        phrase = np.concatenate(self.chunks)
        trailing = int(max(0.0, trim_seconds) * self.sample_rate)
        return phrase[:-trailing] if trailing and len(phrase) > trailing else phrase

    def add(self, pcm: bytes) -> tuple[np.ndarray, str] | None:
        audio = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
        if not len(audio):
            return None
        seconds = len(audio) / self.sample_rate
        rms = float(np.sqrt(np.mean(audio * audio)))
        self.last_rms = rms
        if not self.chunks:
            self.threshold = max(LIVE_VAD_RMS, min(0.04, self.noise_rms * 2.7))
            if rms < self.threshold:
                self.noise_rms = self.noise_rms * 0.96 + rms * 0.04
                self.pre_roll.append(audio)
                pre_roll_samples = sum(len(chunk) for chunk in self.pre_roll)
                while self.pre_roll and pre_roll_samples > int(self.sample_rate * 0.18):
                    pre_roll_samples -= len(self.pre_roll.pop(0))
                return None
            self.chunks = self.pre_roll + [audio]
            self.pre_roll = []
            self.voiced_seconds = seconds
            self.silence_seconds = 0.0
            return None

        self.chunks.append(audio)
        if rms >= self.threshold:
            self.voiced_seconds += seconds
            self.silence_seconds = 0.0
        else:
            self.silence_seconds += seconds

        total_samples = sum(len(chunk) for chunk in self.chunks)
        if self.endpoint_mode == "sentence" and self.voiced_seconds >= 0.35:
            if total_samples >= self.sample_rate * 8:
                return self._candidate(), "max_duration"
            if self.silence_seconds >= 0.75:
                return self._candidate(max(0.0, self.silence_seconds - 0.10)), "pause_fallback"
            if (
                total_samples - self.last_probe_samples >= self.sample_rate * 2.5
                or self.silence_seconds >= 0.18
                and total_samples - self.last_probe_samples >= self.sample_rate * 0.45
            ):
                self.last_probe_samples = total_samples
                return self._candidate(max(0.0, self.silence_seconds - 0.08)), "sentence_probe"
            return None

        if self.silence_seconds < self.pause_seconds:
            return None
        if self.voiced_seconds < LIVE_MIN_SPEECH_SECONDS:
            self.reset()
            return None
        phrase = self._candidate(max(0.0, self.pause_seconds - 0.10))
        self.reset()
        return phrase, "pause"

    def commit(self) -> None:
        self.reset()


def _transcribe_live_phrase(
    phrase: np.ndarray,
    sample_rate: int,
    language: str | None,
    translate: bool,
    source_language: str | None,
    target_language: str | None,
) -> tuple[str, str | None, int]:
    temp_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as temp:
            temp_path = temp.name
        sf.write(temp_path, phrase, sample_rate)
        with MODEL_LOCK:
            METRICS.active("transcribing")
            started = time.perf_counter()
            target = target_language or "English"
            system_prompt = (
                f"Translate spoken {source_language or 'Russian'} into {target}. "
                "Return only the translated text."
                if translate else None
            )
            result = _load_stt(ASR_MODEL).generate(
                temp_path,
                language=target if translate else language,
                system_prompt=system_prompt,
            )
            elapsed_ms = round((time.perf_counter() - started) * 1000)
            METRICS.asr(elapsed_ms / 1000)
            detected = target if translate else (
                _normalize_language(getattr(result, "language", None)) or language
            )
            return _sanitize_live_asr_text(result.text, system_prompt), detected, elapsed_ms
    finally:
        METRICS.idle()
        if temp_path:
            Path(temp_path).unlink(missing_ok=True)


def _sanitize_live_asr_text(text: object, system_prompt: str | None) -> str:
    """Drop translator instructions hallucinated as speech on silent/noisy input."""
    clean = str(text or "").strip()
    if not clean or not system_prompt:
        return clean
    normalized = " ".join(re.findall(r"[a-z]+", clean.lower()))
    leak_markers = (
        "translate spoken",
        "return only",
        "translated text",
        "translation prompt",
        "source language",
        "target language",
    )
    if any(marker in normalized for marker in leak_markers):
        return ""
    prompt_words = set(re.findall(r"[a-z]+", system_prompt.lower()))
    output_words = re.findall(r"[a-z]+", normalized)
    if len(output_words) >= 3:
        overlap = sum(word in prompt_words for word in output_words) / len(output_words)
        if overlap >= 0.7:
            return ""
    return clean


def _stream_clone_pcm(
    ref_audio: str,
    ref_text: str,
    phrase: np.ndarray,
    sample_rate: int,
    language: str | None = None,
    translate: bool = False,
    source_language: str | None = None,
    target_language: str | None = None,
    transcription: tuple[str, str | None, int] | None = None,
):
    """Yield transcript followed by PCM chunks; called by the WebSocket route."""
    temp_path = None
    try:
        text, detected_language, asr_ms = transcription or _transcribe_live_phrase(
            phrase, sample_rate, language, translate, source_language, target_language
        )
        yield "text", {
            "text": text, "language": detected_language, "asr_ms": asr_ms,
        }
        if not text:
            return
        with MODEL_LOCK:
            target = target_language or "English"
            METRICS.active("synthesizing")
            tts_started = time.perf_counter()
            tts = _load(CLONE_MODEL)
            for result in tts.generate(
                text=text,
                ref_audio=ref_audio,
                ref_text=ref_text,
                lang_code=target if translate else _text_language(text, detected_language),
                max_tokens=_tts_token_budget(tts, text),
                temperature=0.7,
                top_p=0.9,
                top_k=30,
                repetition_penalty=1.5,
                stream=True,
                streaming_interval=0.24,
            ):
                pcm = np.clip(result.audio, -1.0, 1.0)
                pcm = (pcm * 32767).astype("<i2").tobytes()
                yield "audio", (int(result.sample_rate), pcm)
            METRICS.tts(time.perf_counter() - tts_started)
    except Exception as error:
        METRICS.error(error)
        raise
    finally:
        METRICS.idle()
        if temp_path:
            Path(temp_path).unlink(missing_ok=True)


def _next_stream_item(stream):
    """Advance a blocking generator without leaking StopIteration into asyncio."""
    try:
        return True, next(stream)
    except StopIteration:
        return False, None


def sampling_controls():
    with gr.Accordion("Advanced settings", open=False):
        with gr.Row():
            temperature = gr.Slider(0.1, 1.5, value=0.9, step=0.05, label="Temperature")
            top_p = gr.Slider(0.1, 1.0, value=1.0, step=0.05, label="Top-p")
        with gr.Row():
            top_k = gr.Slider(1, 100, value=50, step=1, label="Top-k")
            repetition = gr.Slider(
                1.0, 2.0, value=1.05, step=0.05, label="Repetition penalty"
            )
            seed = gr.Number(value=42, precision=0, label="Seed")
    return temperature, top_p, top_k, repetition, seed


def build_ui() -> gr.Blocks:
    if gr is None:
        raise RuntimeError("Web UI requires the optional Gradio dependency.")
    with gr.Blocks(title="Voice clone Studio") as demo:
        gr.Markdown(
            "# Voice clone Studio\n"
            "Local Qwen3-TTS on Apple Silicon. Models are downloaded from Hugging Face "
            "on first use and can run offline afterward."
        )

        with gr.Tab("Design a voice"):
            instruct = gr.Textbox(
                lines=6,
                label="Voice and delivery description",
                info="Describe only a voice you have the right to create or use. No descriptions are stored in the repository.",
            )
            text = gr.Textbox(
                lines=4,
                label="Text to synthesize",
            )
            d_temp, d_top_p, d_top_k, d_rep, d_seed = sampling_controls()
            design_button = gr.Button("Generate", variant="primary")
            design_audio = gr.Audio(label="Result", type="filepath")
            design_stats = gr.Textbox(label="Metrics", interactive=False)

            design_button.click(
                design_voice,
                [text, instruct, d_temp, d_top_p, d_top_k, d_rep, d_seed],
                [design_audio, design_stats],
            )

        with gr.Tab("Clone a voice from audio"):
            gr.Markdown(
                "Use 6–15 seconds of clean speech from one consenting speaker, without music, "
                "reverberation, or background noise. The transcript must match the audio exactly. "
                "**The Base model inherits delivery from the reference and does not accept text "
                "instructions.** The emotion control below is experimental post-processing."
            )
            ref_audio = gr.Audio(
                sources=["upload", "microphone"],
                type="filepath",
                label="Voice reference",
            )
            with gr.Row():
                transcribe_button = gr.Button("Transcribe reference")
                auto_transcribe = gr.Checkbox(
                    value=True,
                    label="Transcribe automatically when the field is empty",
                )
            ref_text = gr.Textbox(
                lines=3,
                label="Reference transcript",
                info="Review the automatic transcript. It should match the audio exactly.",
            )
            stt_status = gr.Textbox(label="Transcription status", interactive=False)
            target_text = gr.Textbox(lines=4, label="New text")
            with gr.Row():
                emotion = gr.Dropdown(
                    choices=list(EMOTION_FX),
                    value="As in the reference",
                    label="Emotion / prosody (experimental)",
                )
                emotion_strength = gr.Slider(
                    0.0,
                    1.0,
                    value=0.7,
                    step=0.05,
                    label="Effect strength",
                )
            c_temp, c_top_p, c_top_k, c_rep, c_seed = sampling_controls()
            clone_button = gr.Button("Clone and synthesize", variant="primary")
            clone_audio = gr.Audio(label="Result", type="filepath")
            clone_stats = gr.Textbox(label="Metrics", interactive=False)

            transcribe_button.click(
                transcribe_reference,
                [ref_audio],
                [ref_text, stt_status],
            )
            clone_button.click(
                clone_voice,
                [
                    ref_audio,
                    ref_text,
                    auto_transcribe,
                    target_text,
                    emotion,
                    emotion_strength,
                    c_temp,
                    c_top_p,
                    c_top_k,
                    c_rep,
                    c_seed,
                ],
                [clone_audio, clone_stats, ref_text],
            )

        with gr.Tab("Live MVP: speech to clone"):
            gr.Markdown(
                "Push-to-talk MVP: record a short phrase and stop recording. It will be "
                "transcribed and synthesized with the selected clone. This is not continuous streaming."
            )
            live_ref_audio = gr.Audio(
                sources=["upload"], type="filepath", label="Voice-cloning sample"
            )
            with gr.Row():
                live_ref_transcribe = gr.Button("Transcribe sample")
                live_warmup = gr.Button("Prepare models")
            live_ref_text = gr.Textbox(
                lines=2,
                label="Sample transcript",
                info="Transcribe once and correct the text if needed.",
            )
            live_ready = gr.Textbox(label="Status", interactive=False)
            mic_audio = gr.Audio(
                sources=["microphone"], type="filepath", label="Your phrase"
            )
            live_seed = gr.Number(value=42, precision=0, label="Seed")
            live_button = gr.Button("Transcribe and synthesize", variant="primary")
            live_text = gr.Textbox(label="Recognized text", interactive=False)
            live_output = gr.Audio(label="Cloned voice", type="filepath")
            live_metrics = gr.Textbox(label="Latency", interactive=False)

            live_ref_transcribe.click(
                transcribe_reference, [live_ref_audio], [live_ref_text, live_ready]
            )
            live_warmup.click(prepare_live, outputs=live_ready)
            live_button.click(
                live_transform,
                [live_ref_audio, live_ref_text, mic_audio, live_seed],
                [live_text, live_output, live_metrics],
            )

        with gr.Tab("Push-to-talk fallback"):
            gr.Markdown(
                "**Reliable recording mode.** In some browsers, Gradio passes only the final "
                "short microphone chunk. This mode records a complete utterance: press Record, "
                "speak, press Stop, and then synthesize the phrase."
            )
            stream_ref_audio = gr.Audio(
                sources=["upload"], type="filepath", label="Voice-cloning sample"
            )
            with gr.Row():
                stream_ref_transcribe = gr.Button("Transcribe sample")
                stream_warmup = gr.Button("Prepare models")
                stream_send = gr.Button("Synthesize phrase", variant="primary")
                stream_inspect = gr.Button("Inspect recording")
            stream_ref_text = gr.Textbox(lines=2, label="Sample transcript")
            stream_input = gr.Audio(
                sources=["microphone"],
                type="filepath",
                label="Microphone: one utterance",
            )
            stream_output = gr.Audio(
                label="Cloned voice", type="filepath", autoplay=True
            )
            stream_text = gr.Textbox(label="Recognized phrase", interactive=False)
            stream_status = gr.Textbox(label="Status / latency", interactive=False)
            stream_debug = gr.Textbox(label="Input WAV diagnostics", interactive=False)

            stream_ref_transcribe.click(
                transcribe_reference, [stream_ref_audio], [stream_ref_text, stream_status]
            )
            stream_warmup.click(prepare_live, outputs=stream_status)
            stream_inspect.click(inspect_recording, stream_input, stream_debug)
            stream_input.stop_recording(inspect_recording, stream_input, stream_debug)
            stream_send.click(
                live_transform,
                [stream_ref_audio, stream_ref_text, stream_input, live_seed],
                [stream_text, stream_output, stream_status],
                concurrency_limit=1,
                show_progress="hidden",
            )
            stream_input.stop_recording(
                live_transform,
                [stream_ref_audio, stream_ref_text, stream_input, live_seed],
                [stream_text, stream_output, stream_status],
                concurrency_limit=1,
                show_progress="hidden",
            )

        with gr.Tab("⚡ Real-time Studio"):
            gr.HTML(
                """
                <header class="studio-hero"><div><div class="studio-eyebrow">LOCAL · PRIVATE · APPLE SILICON</div><h2>Voice clone Studio</h2><p>Create a voice reference, synthesize text, and transform live speech in one workflow.</p></div><div class="studio-badges"><span>Qwen3-ASR</span><span>Qwen3-TTS</span><span>MLX</span></div></header>
                """
            )
            gr.HTML(
                """
                <section id="sample-editor" class="sample-lab">
                  <div class="sample-editor-head"><div><div class="studio-step">01 · VOICE REFERENCE</div><div class="rt-title">Sample Editor</div><div class="rt-sub">Spectrogram · speaker lanes · direct range selection</div></div><span id="sample-time" class="rt-state">0.0 / 10.0 s</span></div>
                  <div class="sample-toolbar">
                    <select id="sample-source" class="rt-control"><option value="microphone">Microphone</option><option value="system">System audio / tab</option></select>
                    <button id="sample-record" class="rt-btn primary" disabled>Initializing…</button><button id="sample-stop" class="rt-btn" disabled>Stop</button>
                    <label class="rt-btn sample-file-label">Load audio<input id="sample-file" type="file" accept="audio/*" disabled></label>
                  </div>
                  <div class="sample-canvas-wrap"><canvas id="sample-spectrogram" class="sample-spectrogram" height="190"></canvas><div class="sample-frequency"><span>8 kHz</span><span>2 kHz</span><span>500 Hz</span><span>80 Hz</span></div></div>
                  <div class="sample-selection-info"><span>Selection</span><strong id="sample-selection-label">0.00 — 0.00 s</strong><span>Playhead</span><strong id="sample-playhead-label">0.00 s</strong><span>Click to listen · drag to select</span></div>
                  <div id="sample-speaker-tracks" class="speaker-tracks"><div class="speaker-empty">Voice A / Voice B / Mixed lanes will appear after analysis</div></div>
                  <details class="speaker-settings"><summary>Voice separation settings</summary><div class="speaker-settings-grid">
                    <label>Sensitivity<select id="sample-speaker-mode" class="rt-control"><option value="conservative">Conservative · fewer voices</option><option value="balanced">Balanced</option><option value="sensitive">Sensitive · more voices</option></select></label>
                    <label>Minimum voice material <input id="sample-min-voice" type="range" min="0.5" max="2.5" value="0.9" step="0.1"><span id="sample-min-voice-label">0.9 s</span></label>
                    <label>Merge gaps up to <input id="sample-merge-gap" type="range" min="0.1" max="1.5" value="0.55" step="0.05"><span id="sample-merge-gap-label">0.55 s</span></label>
                  </div></details>
                  <div class="sample-trim"><label>Start <input id="sample-from" type="range" min="0" max="0" value="0" step="0.05"><span id="sample-from-label">0.00 s</span></label><label>End <input id="sample-to" type="range" min="0" max="0" value="0" step="0.05"><span id="sample-to-label">0.00 s</span></label></div>
                  <div class="sample-actions"><button id="sample-preview" class="rt-btn" disabled>▶ Play selection</button><button id="sample-analyze" class="rt-btn" disabled>Find and label voices</button><button id="sample-use-selection" class="rt-btn primary" disabled>Use selection for cloning</button></div>
                  <div id="sample-status" class="rt-sub">The latest 10 seconds are retained. The spectrogram is computed locally in the browser.</div>
                  <div id="sample-voices" class="voice-pool"></div>
                  <div id="sample-transcript-wrap" hidden><label class="rt-label">Selected voice transcript<textarea id="sample-transcript" class="rt-control" rows="2"></textarea></label><button id="sample-save-text" class="rt-btn">Apply transcript</button></div>
                </section>
                """
            )
            gr.HTML(
                """
                <section id="text-studio" class="studio-section text-studio">
                  <div class="studio-section-head"><div><div class="studio-step">02 · TEXT TO VOICE</div><div class="rt-title">Synthesize with the clone</div><div class="rt-sub">Enter text; the current voice reference will be reused without preparation.</div></div><span id="text-ready" class="studio-pill waiting">Reference required</span></div>
                  <textarea id="text-input" class="studio-textarea" rows="5" maxlength="2000" placeholder="Type or paste text to synthesize…"></textarea>
                  <div class="text-toolbar"><span id="text-count">0 / 2000</span><div class="rt-actions"><button id="text-clear" class="rt-btn">Clear</button><button id="text-generate" class="rt-btn primary" disabled>Generate track</button></div></div>
                  <div id="text-status" class="rt-sub">Prepare a voice in Sample Editor.</div>
                  <div id="text-history" class="text-history"><div class="text-empty">Generated tracks will appear here</div></div>
                </section>
                """
            )
            with gr.Row(equal_height=False):
                with gr.Column(scale=4, min_width=320, visible=False):
                    rt_ref_audio = gr.Audio(
                        sources=["upload", "microphone"],
                        type="filepath",
                        label="1 · Voice sample (upload / record / trim)",
                    )
                    rt_ref_prepare = gr.Button(
                        "Prepare voice", variant="primary", size="lg"
                    )
                    rt_ref_text = gr.Textbox(
                        lines=3,
                        label="2 · Sample transcript",
                        info="Review the prepared transcript; it must match the audio.",
                    )
                    rt_ref_status = gr.Textbox(
                        label="Model readiness", interactive=False
                    )
                with gr.Column(scale=7, min_width=480):
                    gr.HTML(
                        """
                        <div id="rt-shell"><div id="realtime-voice" class="rt-panel" data-state="IDLE">
                          <div class="rt-top"><div><div class="studio-step">03 · LIVE VOICE</div><div class="rt-title">Live Voice</div><div class="rt-sub">PCM → Qwen3-ASR → Qwen3-TTS</div></div>
                            <div class="rt-actions"><button id="rt-start" class="rt-btn primary" disabled>Initializing…</button><button id="rt-stop" class="rt-btn" disabled>Stop</button></div>
                          </div>
                          <div class="rt-grid">
                            <div class="rt-card"><div class="rt-label"><span id="rt-state" class="rt-state">IDLE</span> · <span id="rt-source">No source selected</span> · <span id="rt-level">— dB</span></div>
                              <div id="rt-status" class="rt-status">Prepare a voice reference in Sample Editor</div><div class="rt-meter-bg"><div id="rt-meter" class="rt-meter"></div></div>
                              <div class="rt-metrics">
                                <div class="rt-metric"><div class="rt-label">Pause</div><div id="rt-vad" class="rt-value">—</div></div>
                                <div class="rt-metric"><div class="rt-label">ASR</div><div id="rt-asr" class="rt-value">—</div></div>
                                <div class="rt-metric"><div class="rt-label">First audio</div><div id="rt-ttfb" class="rt-value">—</div></div>
                                <div class="rt-metric"><div class="rt-label">Phrase</div><div id="rt-phrase" class="rt-value">—</div></div>
                                <div class="rt-metric"><div class="rt-label">Playback</div><div id="rt-queue" class="rt-value">0.0 s</div></div>
                                <div class="rt-metric"><div class="rt-label">Output</div><div id="rt-device" class="rt-value">—</div></div>
                              </div>
                            </div>
                            <div class="rt-card"><div class="rt-label">Latest transcript</div><div id="rt-text" class="rt-transcript">—</div>
                              <label class="rt-label">Source<select id="rt-input" class="rt-control"><option value="microphone">Microphone</option><option value="system">System audio / tab</option></select></label>
                              <label class="rt-label">Pause mode<select id="rt-pause" class="rt-control"><option value="420">Fast · 420 ms</option><option value="550">Balanced · 550 ms</option><option value="750">Stable · 750 ms</option></select></label>
                              <label class="rt-label">Audio output<select id="rt-output" class="rt-control"><option>System</option></select></label>
                              <button id="rt-refresh-output" class="rt-btn" style="width:100%;margin-top:8px">Refresh devices</button>
                              <div id="rt-routing" class="rt-sub" style="margin-top:12px">Install BlackHole 2ch for a virtual microphone.</div>
                            </div>
                          </div>
                        </div></div>
                        """
                    )
            rt_ref_prepare.click(
                prepare_websocket_reference,
                rt_ref_audio,
                [rt_ref_text, rt_ref_status],
            )
            rt_ref_text.change(update_websocket_reference_text, rt_ref_text, rt_ref_status)

        demo.load(None, js=LIVE_CLIENT_JS, queue=False)
    return demo


def start_live_service(
    port: int = LIVE_PORT,
    *,
    block: bool = False,
    parent_pid: int | None = None,
    instance_id: str = "web",
) -> uvicorn.Server:
    _restore_reference()
    live_api = FastAPI()
    speaker_pool: dict[str, dict] = {}
    started_at = time.time()
    live_api.add_middleware(
        CORSMiddleware,
        allow_origins=["http://127.0.0.1:7860"],
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @live_api.middleware("http")
    async def observe_requests(request: Request, call_next):
        request_started = time.perf_counter()
        try:
            return await call_next(request)
        except Exception as error:
            METRICS.error(error)
            raise
        finally:
            METRICS.response(time.perf_counter() - request_started)

    @live_api.post("/sample/analyze")
    async def analyze_sample(request: Request):
        try:
            sample_rate = int(request.headers.get("x-sample-rate", "44100"))
            min_voice_seconds = float(request.headers.get("x-min-voice-seconds", "0.9"))
            merge_gap = float(request.headers.get("x-merge-gap", "0.55"))
        except ValueError as error:
            raise HTTPException(400, "Invalid speaker analysis parameters.") from error
        speaker_mode = request.headers.get("x-speaker-mode", "conservative")
        if not 8000 <= sample_rate <= 96000:
            raise HTTPException(400, "Invalid sample rate.")
        raw = await request.body()
        METRICS.traffic(incoming=len(raw))
        if len(raw) % 2:
            raise HTTPException(400, "Invalid PCM buffer.")
        audio = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
        audio = audio[-sample_rate * 10 :]
        try:
            analysis = analyze_speaker_pool(
                audio,
                sample_rate,
                speaker_mode,
                min_voice_seconds,
                merge_gap,
            )
        except ValueError as error:
            raise HTTPException(400, str(error)) from error
        response = []
        for index, voice in enumerate(analysis["voices"]):
            voice_id = uuid.uuid4().hex
            speaker_pool[voice_id] = voice
            response.append({
                "id": voice_id, "name": f"Voice {chr(65 + index)}",
                "url": f"http://127.0.0.1:{port}/sample/audio/{voice_id}",
                **{key: value for key, value in voice.items() if key != "path"},
            })
        return {
            "voices": response,
            "mixed": analysis["mixed"],
            "duration": analysis["duration"],
            "settings": analysis["settings"],
            "heuristic": True,
        }

    @live_api.get("/sample/audio/{voice_id}")
    async def sample_audio(voice_id: str):
        voice = speaker_pool.get(voice_id)
        if not voice:
            raise HTTPException(404, "Voice not found.")
        return FileResponse(voice["path"], media_type="audio/wav")

    @live_api.post("/sample/select/{voice_id}")
    async def select_sample_voice(voice_id: str, request: Request):
        voice = speaker_pool.get(voice_id)
        if not voice:
            raise HTTPException(404, "Voice not found.")
        requested_language = _normalize_language(request.headers.get("x-asr-language"))
        started = time.perf_counter()
        def prepare_voice() -> tuple[str, str | None]:
            try:
                with MODEL_LOCK:
                    METRICS.active("transcribing")
                    asr_started = time.perf_counter()
                    result = _load_stt(ASR_MODEL).generate(
                        voice["path"], language=requested_language
                    )
                    METRICS.asr(time.perf_counter() - asr_started)
                    text = result.text.strip()
                    language = _normalize_language(getattr(result, "language", None)) or requested_language
                    if not text:
                        raise HTTPException(400, "ASR did not recognize the selected voice.")
                    METRICS.active("loading_voice_engine")
                    _load(CLONE_MODEL)
                    _set_reference(voice["path"], text, language)
                    return text, language
            finally:
                METRICS.idle()

        text, language = await asyncio.to_thread(prepare_voice)
        return {
            "text": text, "language": language,
            "seconds": voice["seconds"], "elapsed": round(time.perf_counter() - started, 2),
        }

    @live_api.post("/sample/select-region")
    async def select_sample_region(request: Request):
        sample_rate = int(request.headers.get("x-sample-rate", "44100"))
        requested_language = _normalize_language(request.headers.get("x-asr-language"))
        raw = await request.body()
        METRICS.traffic(incoming=len(raw))
        if len(raw) % 2 or not 8000 <= sample_rate <= 96000:
            raise HTTPException(400, "Invalid PCM buffer.")
        audio = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
        if len(audio) < sample_rate or float(np.sqrt(np.mean(audio * audio))) < 0.006:
            raise HTTPException(400, "Select at least one second of sufficiently loud speech.")
        path = OUTPUT_DIR / f"selected-{datetime.now().strftime('%Y%m%d-%H%M%S-%f')}.wav"
        sf.write(path, audio, sample_rate)
        started = time.perf_counter()
        def prepare_region() -> tuple[str, str | None]:
            try:
                with MODEL_LOCK:
                    METRICS.active("transcribing")
                    asr_started = time.perf_counter()
                    result = _load_stt(ASR_MODEL).generate(
                        str(path), language=requested_language
                    )
                    METRICS.asr(time.perf_counter() - asr_started)
                    text = result.text.strip()
                    language = _normalize_language(getattr(result, "language", None)) or requested_language
                    if not text:
                        raise HTTPException(400, "ASR did not recognize the selected range.")
                    METRICS.active("loading_voice_engine")
                    _load(CLONE_MODEL)
                    _set_reference(str(path), text, language)
                    return text, language
            finally:
                METRICS.idle()

        text, language = await asyncio.to_thread(prepare_region)
        return {
            "text": text, "language": language,
            "seconds": round(len(audio) / sample_rate, 2),
            "elapsed": round(time.perf_counter() - started, 2),
        }

    @live_api.post("/sample/transcript")
    async def update_sample_transcript(request: Request):
        payload = await request.json()
        text = str(payload.get("text", "")).strip()
        if not text:
            raise HTTPException(400, "The transcript cannot be empty.")
        _set_reference(WEBSOCKET_REFERENCE_AUDIO, text)
        return {"ok": True}

    @live_api.get("/library")
    async def list_voice_library():
        with VOICE_LIBRARY_LOCK:
            return {"voices": _load_voice_library()}

    @live_api.post("/library/save")
    async def save_library_voice(request: Request):
        payload = await request.json()
        name = str(payload.get("name", "")).strip()
        if not name:
            raise HTTPException(400, "Enter a name for the voice.")
        if len(name) > 80:
            raise HTTPException(400, "Voice names are limited to 80 characters.")
        ref_audio = WEBSOCKET_REFERENCE_AUDIO
        ref_text = WEBSOCKET_REFERENCE_TEXT
        if not ref_audio or not ref_text or not Path(ref_audio).is_file():
            raise HTTPException(400, "Prepare a voice reference before saving it.")
        with VOICE_LIBRARY_LOCK:
            voices = _load_voice_library()
            existing = next(
                (voice for voice in voices if str(voice.get("name", "")).casefold() == name.casefold()),
                None,
            )
            voice_id = str(existing.get("id")) if existing else uuid.uuid4().hex
            VOICE_LIBRARY_DIR.mkdir(parents=True, exist_ok=True)
            audio_path = VOICE_LIBRARY_DIR / f"{voice_id}.wav"
            shutil.copyfile(ref_audio, audio_path)
            item = {
                "id": voice_id,
                "name": name,
                "audio": str(audio_path),
                "text": ref_text,
                "language": WEBSOCKET_REFERENCE_LANGUAGE,
                "seconds": round(sf.info(audio_path).duration, 2),
                "created_at": existing.get("created_at") if existing else time.time(),
                "updated_at": time.time(),
            }
            voices = [voice for voice in voices if str(voice.get("id")) != voice_id]
            voices.insert(0, item)
            _save_voice_library(voices)
        return item

    @live_api.post("/library/select/{voice_id}")
    async def select_library_voice(voice_id: str):
        with VOICE_LIBRARY_LOCK:
            voice = next(
                (item for item in _load_voice_library() if str(item.get("id")) == voice_id),
                None,
            )
        if not voice:
            raise HTTPException(404, "Saved voice not found.")
        started = time.perf_counter()

        def activate_voice() -> None:
            try:
                with MODEL_LOCK:
                    METRICS.active("loading_voice_engine")
                    _load(CLONE_MODEL)
                    _set_reference(
                        str(voice["audio"]),
                        str(voice["text"]),
                        _normalize_language(voice.get("language")),
                    )
            finally:
                METRICS.idle()

        await asyncio.to_thread(activate_voice)
        return {
            "text": voice["text"],
            "language": voice.get("language"),
            "seconds": voice["seconds"],
            "elapsed": round(time.perf_counter() - started, 2),
        }

    @live_api.delete("/library/{voice_id}")
    async def delete_library_voice(voice_id: str):
        """Remove one saved voice and its copied reference audio."""
        with VOICE_LIBRARY_LOCK:
            voices = _load_voice_library()
            voice = next(
                (item for item in voices if str(item.get("id")) == voice_id),
                None,
            )
            if not voice:
                raise HTTPException(404, "Saved voice not found.")
            remaining = [item for item in voices if str(item.get("id")) != voice_id]
            audio_path = Path(str(voice.get("audio", ""))).expanduser().resolve()
            library_root = VOICE_LIBRARY_DIR.expanduser().resolve()
            active_path = Path(WEBSOCKET_REFERENCE_AUDIO).expanduser().resolve() \
                if WEBSOCKET_REFERENCE_AUDIO else None
            if audio_path.parent == library_root and audio_path != active_path and audio_path.is_file():
                audio_path.unlink()
            _save_voice_library(remaining)
        return {"ok": True, "id": voice_id}

    @live_api.get("/health")
    async def live_health():
        return {
            "service": "voice-clone-studio",
            "pid": os.getpid(),
            "parent_pid": parent_pid,
            "instance_id": instance_id,
            "started_at": started_at,
            "busy": MODEL_LOCK.locked(),
            "ready": bool(WEBSOCKET_REFERENCE_AUDIO and WEBSOCKET_REFERENCE_TEXT),
            "asr_loaded": STT_MODEL is not None,
            "tts_loaded": MODEL_ID == CLONE_MODEL,
            "asr_state": (
                "working" if METRICS.active_operation == "transcribing"
                else "ready" if STT_MODEL is not None else "unloaded"
            ),
            "tts_state": (
                "working" if METRICS.active_operation in {"loading_voice_engine", "synthesizing"}
                else "ready" if MODEL_ID == CLONE_MODEL else "unloaded"
            ),
            "reference_language": WEBSOCKET_REFERENCE_LANGUAGE,
            **METRICS.snapshot(started_at),
        }

    @live_api.post("/text/synthesize")
    async def synthesize_typed_text(request: Request):
        payload = await request.json()
        text = str(payload.get("text", "")).strip()
        if not text:
            raise HTTPException(400, "Enter text to synthesize.")
        if len(text) > 2000:
            raise HTTPException(400, "The maximum length is 2,000 characters.")
        ref_audio = WEBSOCKET_REFERENCE_AUDIO
        ref_text = WEBSOCKET_REFERENCE_TEXT
        if not ref_audio or not ref_text:
            raise HTTPException(400, "Prepare a clone reference first.")
        # Delivery is optional: without it a take sounds exactly as it did before.
        def number(key: str, fallback: float, low: float, high: float) -> float:
            try:
                return min(max(float(payload.get(key, fallback)), low), high)
            except (TypeError, ValueError):
                return fallback

        emotion = _emotion_key(payload.get("emotion", "As in the reference"))
        emotion_strength = number("emotion_strength", 0.0, 0.0, 1.0)
        pace = number("pace", 1.0, 0.6, 1.6)
        pitch_shift = number("pitch", 0.0, -6.0, 6.0)
        temperature = number("temperature", 0.7, 0.1, 1.5)
        started = time.perf_counter()
        def generate_track():
            try:
                with MODEL_LOCK:
                    METRICS.active("synthesizing")
                    tts_started = time.perf_counter()
                    mx.random.seed(int(payload.get("seed", 42)))
                    model = _load(CLONE_MODEL)
                    result = _save(
                        model.generate(
                            text=text,
                            ref_audio=ref_audio,
                            ref_text=ref_text,
                            lang_code=_text_language(text, WEBSOCKET_REFERENCE_LANGUAGE),
                            max_tokens=_tts_token_budget(model, text),
                            temperature=temperature,
                            top_p=0.9,
                            top_k=30,
                            repetition_penalty=1.35,
                            verbose=False,
                        ),
                        "typed",
                        emotion,
                        emotion_strength,
                        pace,
                        pitch_shift,
                    )
                    METRICS.tts(time.perf_counter() - tts_started)
                    return result
            finally:
                METRICS.idle()

        try:
            path, stats = await asyncio.to_thread(generate_track)
        except Exception as error:
            raise HTTPException(500, f"Synthesis error: {error}") from error
        filename = Path(path).name
        METRICS.traffic(incoming=len(text.encode("utf-8")), outgoing=Path(path).stat().st_size)
        return {
            "url": f"http://127.0.0.1:{port}/output/{filename}",
            "filename": filename,
            "duration": round(sf.info(path).duration, 2),
            "elapsed": round(time.perf_counter() - started, 2),
            "stats": stats,
        }

    @live_api.get("/output/{filename}")
    async def generated_output(filename: str):
        if Path(filename).name != filename or not filename.startswith("typed-"):
            raise HTTPException(404, "Audio track not found.")
        path = OUTPUT_DIR / filename
        if not path.is_file():
            raise HTTPException(404, "Audio track not found.")
        return FileResponse(path, media_type="audio/wav", filename=filename)

    @live_api.websocket("/ws")
    async def live_websocket(websocket: WebSocket):
        await websocket.accept()
        receiver_task = None
        telemetry_task = None
        send_lock = asyncio.Lock()

        async def send_json(payload):
            async with send_lock:
                await websocket.send_json(payload)
        try:
            config = await websocket.receive_json()
            ref_audio = WEBSOCKET_REFERENCE_AUDIO
            ref_text = WEBSOCKET_REFERENCE_TEXT
            sample_rate = int(config.get("sample_rate", 44100))
            requested_language = _normalize_language(config.get("language"))
            translate = bool(config.get("translate", False))
            source_language = _normalize_language(config.get("source_language")) or "Russian"
            target_language = _normalize_language(config.get("target_language")) or "English"
            endpoint_mode = "sentence" if config.get("endpoint_mode") == "sentence" else "pause"
            pause_seconds = min(max(float(config.get("pause_seconds", LIVE_PAUSE_SECONDS)), 0.35), 1.2)
            if not ref_audio or not ref_text or not 8000 <= sample_rate <= 96000:
                await send_json({"type": "error", "message": "A sample, its transcript, and a valid sample rate are required."})
                return
            buffer = PhraseBuffer(sample_rate, pause_seconds, endpoint_mode)
            await send_json({
                "type": "status",
                "message": "Listening · smart sentence endpointing" if endpoint_mode == "sentence" else "Listening…",
            })
            input_queue = asyncio.Queue(maxsize=2048)
            telemetry = LiveTelemetry(sample_rate)

            async def report_telemetry():
                while True:
                    await send_json(telemetry.snapshot(time.perf_counter()))
                    await asyncio.sleep(0.25)

            telemetry_task = asyncio.create_task(report_telemetry())

            async def receive_audio() -> None:
                try:
                    while True:
                        message = await websocket.receive()
                        if message.get("type") == "websocket.disconnect":
                            break
                        pcm = message.get("bytes")
                        if pcm is not None:
                            METRICS.traffic(incoming=len(pcm))
                            received_at = time.perf_counter()
                            telemetry.received(pcm, received_at)
                            await input_queue.put((pcm, received_at))
                except WebSocketDisconnect:
                    pass
                finally:
                    if not asyncio.current_task().cancelling():
                        await input_queue.put(None)

            receiver_task = asyncio.create_task(receive_audio())
            METRICS.active("listening")
            while True:
                packet = await input_queue.get()
                if packet is None:
                    break
                pcm, received_at = packet
                telemetry.consumed(pcm)
                candidate = buffer.add(pcm)
                telemetry.phase = "endpoint" if buffer.chunks else "listening"
                if candidate is None:
                    continue
                phrase, endpoint_reason = candidate
                if len(phrase) < sample_rate * 0.25:
                    continue
                transcription = None
                request_started = time.perf_counter()
                telemetry.phase = "recognizing"
                telemetry.phrase_end_received_at = received_at
                if endpoint_mode == "sentence":
                    await send_json({"type": "probe", "message": "Checking sentence boundary…"})
                    transcription = await asyncio.to_thread(
                        _transcribe_live_phrase,
                        phrase, sample_rate, requested_language, translate,
                        source_language, target_language,
                    )
                    text = transcription[0].rstrip()
                    sentence_complete = text.endswith((".", "!", "?", "。", "！", "？"))
                    if endpoint_reason not in {"max_duration", "pause_fallback"} and not sentence_complete:
                        await send_json({"type": "status", "message": "Listening · sentence continues"})
                        telemetry.phrase_end_received_at = None
                        telemetry.phase = "endpoint"
                        continue
                    buffer.commit()
                telemetry.phrase_id += 1
                phrase_id = telemetry.phrase_id
                await asyncio.to_thread(sf.write, OUTPUT_DIR / "live-input-last.wav", phrase, sample_rate)
                await send_json({
                    "type": "busy", "phrase_id": phrase_id, "input_seconds": len(phrase) / sample_rate,
                    "endpoint": endpoint_reason,
                })
                first_audio = True
                failed = False
                output_seconds = 0.0
                tts_started = None
                stream = iter(_stream_clone_pcm(
                    ref_audio, ref_text, phrase, sample_rate, requested_language,
                    translate, source_language, target_language,
                    transcription,
                ))
                while True:
                    has_item, item = await asyncio.to_thread(_next_stream_item, stream)
                    if not has_item:
                        break
                    kind, payload = item
                    if kind == "text":
                        if not payload["text"]:
                            await send_json({
                                "type": "warning",
                                "message": "No speech recognized · still listening",
                            })
                            failed = True
                            break
                        telemetry.phase = "synthesizing"
                        tts_started = time.perf_counter()
                        await send_json({"type": "text", "phrase_id": phrase_id, **payload})
                    else:
                        out_rate, out_pcm = payload
                        if first_audio:
                            await send_json({
                                "type": "audio_meta", "phrase_id": phrase_id, "sample_rate": out_rate,
                                "first_audio_ms": round((time.perf_counter() - request_started) * 1000),
                            })
                            first_audio = False
                        output_seconds += len(out_pcm) / 2 / out_rate
                        async with send_lock:
                            await websocket.send_bytes(out_pcm)
                        METRICS.traffic(outgoing=len(out_pcm))
                if not failed:
                    elapsed = max(0.001, time.perf_counter() - (tts_started or request_started))
                    telemetry.last_speed = round(output_seconds / elapsed, 2)
                    await send_json({"type": "done", "phrase_id": phrase_id,
                                     "output_seconds": output_seconds, "synthesis_speed": telemetry.last_speed})
                telemetry.phrase_end_received_at = None
                telemetry.phase = "listening"
                METRICS.active("listening")
        except WebSocketDisconnect:
            pass
        except Exception as error:
            try:
                await send_json({"type": "error", "message": str(error)})
            except Exception:
                pass
        finally:
            tasks = [task for task in (receiver_task, telemetry_task) if task is not None]
            for task in tasks:
                task.cancel()
            if tasks:
                await asyncio.gather(*tasks, return_exceptions=True)
            METRICS.idle()

    config = uvicorn.Config(live_api, host="127.0.0.1", port=port, log_level="warning")
    server = uvicorn.Server(config)

    if parent_pid:
        def watch_parent() -> None:
            while not server.should_exit:
                if os.getppid() != parent_pid:
                    server.should_exit = True
                    break
                time.sleep(0.25)

        threading.Thread(target=watch_parent, name="parent-watch", daemon=True).start()

    if block:
        server.run()
    else:
        threading.Thread(target=server.run, name=f"live-api-{port}", daemon=True).start()
    return server


def main() -> None:
    global WEB_PROCESS_LOCK
    try:
        WEB_PROCESS_LOCK = _acquire_process_lock(ROOT / ".voice-clone-web.lock")
    except RuntimeError as error:
        raise SystemExit(str(error)) from error
    demo = build_ui()
    demo.queue(default_concurrency_limit=1)
    start_live_service()
    demo.launch(
        inbrowser=True,
        server_name="127.0.0.1",
        server_port=7860,
        show_error=True,
        css=LIVE_CSS,
    )


if __name__ == "__main__":
    main()
