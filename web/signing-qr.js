'use strict';
// Public QR data only. Size and fountain-work limits match the native clients.
(() => {
  const MAX = 160 * 1024, alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  const fail = text => { throw new Error(text || 'Invalid signing QR. Reset the scanner and try again.'); };
  function base32(data) {
    let acc=0,bits=0,out='';
    for (const byte of data) { acc=(acc<<8)|byte; bits+=8; while(bits>=5){bits-=5;out+=alphabet[(acc>>>bits)&31];} acc&=(1<<bits)-1; }
    if(bits) out+=alphabet[(acc<<(5-bits))&31]; return out;
  }
  function decode32(text) {
    if (![0,2,4,5,7].includes(text.length%8)) fail();
    let acc=0,bits=0,out=[];
    for(const c of text){const n=alphabet.indexOf(c);if(n<0)fail();acc=(acc<<5)|n;bits+=5;if(bits>=8){bits-=8;out.push((acc>>>bits)&255);}acc&=(1<<bits)-1;}
    if(acc)fail();return Uint8Array.from(out);
  }
  function binary(text) {
    if (!text || text.length>MAX*2) fail('QR response is too large.');
    let bytes;
    if (/^(?:[0-9a-fA-F]{2})+$/.test(text)) bytes=Uint8Array.from(text.match(/../g), h=>parseInt(h,16));
    else { if(!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(text))fail(); bytes=Uint8Array.from(atob(text), c=>c.charCodeAt(0)); }
    if(!bytes.length || bytes.length>MAX)fail();return bytes;
  }
  const toBase64 = bytes => { let text=''; for(const byte of bytes)text+=String.fromCharCode(byte);return btoa(text); };
  function frames(bytes) {
    if(!bytes.length||bytes.length>MAX)fail();const text=base32(bytes), count=Math.ceil(text.length/240), number=n=>n.toString(36).toUpperCase().padStart(2,'0');
    if(count>1295)fail();return Array.from({length:count},(_,i)=>'B$2P'+number(count)+number(i)+text.slice(i*240,(i+1)*240));
  }
  // Parse only the two CBOR shapes allowed by crypto-psbt. No recursive values.
  function cbor(bytes, multipart) {
    let offset=0;
    const read=(major)=>{
      const tag=bytes[offset++];if(tag===undefined||(tag>>>5)!==major)fail();const code=tag&31;
      let value=code;
      if(code>=24){const size=({24:1,25:2,26:4})[code];if(!size||offset+size>bytes.length)fail();value=0;for(let i=0;i<size;i++)value=value*256+bytes[offset++];}
      return value;
    };
    const data=()=>{const size=read(2);if(size<1||size>MAX+8||offset+size!==bytes.length)fail();return bytes.slice(offset,offset+size);};
    if(!multipart)return data();
    if(read(4)!==5)fail();const fields=[read(0),read(0),read(0),read(0)];return [...fields,data()];
  }
  async function inflate(bytes) {
    const stream=new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate-raw')).getReader();
    const chunks=[];let size=0;
    try {while(true){const {value,done}=await stream.read();if(done)break;size+=value.length;if(size>MAX)fail('QR response expands beyond the size limit.');chunks.push(value);}}
    finally {await stream.cancel();}
    const output=new Uint8Array(size);let offset=0;for(const chunk of chunks){output.set(chunk,offset);offset+=chunk.length;}return output;
  }
  class Collector {
    constructor(){this.identity=null;this.parts=new Map();this.seen=new Set();this.total=0;this.received=0;this.size=0;this.ur=new PaperclipQRVendor.URDecoder();this.finished=false;}
    async accept(raw, publicKey=false) {
      if(this.finished)return null;
      if(this.publicWalletMode!==undefined&&this.publicWalletMode!==publicKey)fail('Mixed QR requests. Reset the scanner.');this.publicWalletMode=publicKey;
      if(typeof raw!=='string'||new TextEncoder().encode(raw).length>4096)fail();const text=raw.trim();let output;
      if(text.toLowerCase().startsWith('ur:')) {
        const fields=text.toLowerCase().split('/');
        if(publicKey||fields[0]!=='ur:crypto-psbt'||![2,3].includes(fields.length)||text.length>8192)fail('Export the public account as plain QR or BBQr. Signed PSBT URs are supported.');
        const hex=PaperclipQRVendor.Bytewords.decode(fields.at(-1),'minimal');
        const bytes=Uint8Array.from(hex.match(/../g)||[], h=>parseInt(h,16));
        let identity='ur:single';
        if(fields.length===3){
          const [seq,count,length,checksum,fragment]=cbor(bytes,true);
          if(seq<1||count<1||count>1295||length<1||length>MAX+8||fragment.length>2048||fragment.length*(count-1)>=length||length>fragment.length*count||fields[1]!==seq+'-'+count)fail();
          identity=`ur:${count}:${length}:${checksum}:${fragment.length}`;this.total=count;
        } else {cbor(bytes,false);this.total=1;}
        if(this.identity&&this.identity!==identity)fail('QR frames belong to different requests. Reset the scanner.');this.identity=identity;
        const normalized=text.toLowerCase();if(this.seen.has(normalized))return null;if(this.seen.size>=4096)fail('Too many QR fragments. Reset the scanner.');this.seen.add(normalized);
        if(!this.ur.receivePart(normalized))fail();this.received=this.ur.receivedPartIndexes().length;
        if(!this.ur.isComplete())return null;if(!this.ur.isSuccess())fail();output=cbor(this.ur.resultUR().cbor,false);
      } else if(text.startsWith('B$')) {
        if(text.length<9||!['H','2','Z'].includes(text[2])||!(publicKey?['U','J']:['P','T']).includes(text[3])||!/^[0-9A-Z]{4}$/.test(text.slice(4,8)))fail();
        const count=parseInt(text.slice(4,6),36),index=parseInt(text.slice(6,8),36),identity=text.slice(0,6),part=text.slice(8);
        if(!count||count>1295||index>=count)fail();if(this.identity&&this.identity!==identity)fail('Mixed QR requests. Reset the scanner.');this.identity=identity;this.total=count;
        if(this.parts.has(index)){if(this.parts.get(index)!==part)fail('Conflicting QR frames.');return null;}
        this.size+=part.length;if(this.size>MAX*2)fail();this.parts.set(index,part);this.received=this.parts.size;if(this.received!==count)return null;
        const decoded=Array.from({length:count},(_,i)=>{const part=this.parts.get(i);if(text[2]==='H'&&!/^(?:[0-9A-F]{2})+$/.test(part))fail();return text[2]==='H'?binary(part):decode32(part);});
        output=new Uint8Array(decoded.reduce((n,part)=>n+part.length,0));let offset=0;for(const part of decoded){output.set(part,offset);offset+=part.length;}if(text[2]==='Z')output=await inflate(output);
      } else if(/^p\d+of\d+ /i.test(text)) {
        const match=/^p(\d+)of(\d+) (.+)$/i.exec(text);if(!match)fail();const index=Number(match[1]),count=Number(match[2]),identity='parts:'+count;
        if(!count||count>1295||index<1||index>count||match[3].length>2048)fail();if(this.identity&&this.identity!==identity)fail();this.identity=identity;this.total=count;
        if(this.parts.has(index)){if(this.parts.get(index)!==match[3])fail();return null;}
        this.size+=match[3].length;if(this.size>MAX*2)fail();this.parts.set(index,match[3]);this.received=this.parts.size;if(this.received!==count)return null;
        const joined=Array.from({length:count},(_,i)=>this.parts.get(i+1)).join('');output=publicKey?new TextEncoder().encode(joined):binary(joined);
      } else {
        if(this.identity)fail('Mixed QR requests. Reset the scanner.');output=publicKey?new TextEncoder().encode(text):binary(text);
      }
      if(!output.length||output.length>MAX)fail();this.finished=true;
      if(publicKey){const key=new TextDecoder('utf-8',{fatal:true}).decode(output).trim();if(key.length>4096||/\b(?:xprv|tprv|yprv|zprv|uprv|vprv)/i.test(key)||key.split(/\s+/).length>=12)fail('Import only a public account key or descriptor. Keep seed words on your signer.');return key;}
      return output;
    }
  }
  window.PaperclipSigningQR={MAX,frames,binary,toBase64,Collector};
})();
