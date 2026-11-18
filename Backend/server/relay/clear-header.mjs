// Older downloader versions decrypted samples and restored clear sample entries,
// but left auxiliary CENC boxes. Normalize only structurally verified clear tracks.
// No ciphertext is decrypted here, and sample bytes/offsets are never changed.
const bad = () => Object.assign(new Error('UNSUPPORTED_CLEAR_HEADER'), { code: 'UNSUPPORTED_CLEAR_HEADER', status: 502 });
export function clearHeaderPatches(data) {
  let count = 0;
  function boxes(start, end) {
    const result = [];
    while (start < end) {
      if (++count > 10000 || start + 8 > end) throw bad();
      let size = data.readUInt32BE(start), header = 8;
      if (size === 1) { if (start+16>end) throw bad(); size=Number(data.readBigUInt64BE(start+8)); header=16; }
      if (!size) size=end-start;
      if (!Number.isSafeInteger(size) || size<header || start+size>end) throw bad();
      result.push({ start, end:start+size, body:start+header, type:data.toString('ascii',start+4,start+8) }); start+=size;
    }
    return result;
  }
  const top=boxes(0,data.length), movie=top.find(b=>b.type==='moov');
  if (!movie) return [];
  const children=boxes(movie.body,movie.end), patches=[];
  if (children.some(b=>['mvex','pssh'].includes(b.type))) throw bad();
  const child=(parent,type)=>{ const result=boxes(parent.body,parent.end).filter(b=>b.type===type); if(result.length!==1) throw bad();return result[0]; };
  for (const track of children.filter(b=>b.type==='trak')) {
    const table=child(child(child(track,'mdia'),'minf'),'stbl'), entries=boxes(table.body,table.end);
    const sd=entries.filter(b=>b.type==='stsd'); if(sd.length!==1 || sd[0].body+8>sd[0].end) throw bad();
    const descriptions=boxes(sd[0].body+8,sd[0].end);
    if (!descriptions.length || descriptions.length!==data.readUInt32BE(sd[0].body+4)) throw bad();
    for(const entry of descriptions) {
      let extra;
      if(['avc1','avc3','hvc1','hev1'].includes(entry.type)) extra=78;
      else if(entry.type==='mp4a') {
        if(entry.body+28>entry.end) throw bad();
        const version=data.readUInt16BE(entry.body+8); extra=version===0?28:version===1?44:version===2?64:NaN;
      } else throw bad();
      if(!Number.isFinite(extra)||entry.body+extra>entry.end) throw bad();
      if(boxes(entry.body+extra,entry.end).some(b=>['sinf','schm','schi','tenc','pssh'].includes(b.type))) throw bad();
    }
    for (const box of entries) {
      if (['sgpd','sbgp'].includes(box.type) && box.body+8<=box.end && data.toString('ascii',box.body+4,box.body+8)==='seig') throw bad();
      if (['senc','saiz','saio'].includes(box.type)) patches.push(box);
    }
  }
  return patches;
}
export function applyClearHeaderPatches(data, offset, patches) {
  for(const box of patches) {
    const start=Math.max(offset,box.body), end=Math.min(offset+data.length,box.end);
    if(start<end) data.fill(0,start-offset,end-offset);
    const tag=Buffer.from('free');
    for(let i=0;i<4;i++) { const at=box.start+4+i-offset; if(at>=0&&at<data.length) data[at]=tag[i]; }
  }
  return data;
}
