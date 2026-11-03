/* Geometry adapted from Maple/Thinking.swift, a port of Thinking Orbs by Jakub Antalik.
MIT License
Copyright (c) 2026 Jakub Antalik
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE. */
const fullerOriginal = {lanes:11,segments:44,inner:.56,dotScale:1.05};
const opal = [[.48,.77,.80],[.63,.57,.81],[.84,.64,.74],[.84,.76,.55]];
function orbDots(option,t){
  const radius=32*.78,base=radius/(1+.85*.23*.368),size=Math.pow(64/300,.6),dots=[];
  for(let lane=0;lane<option.lanes;lane++){
    const u=lane/(option.lanes-1),nativeLane=u*10,offset=(nativeLane-5)*.075,edge=Math.abs(nativeLane-5)/5;
    for(let segment=0;segment<option.segments;segment++){
      const a=segment/option.segments*2*Math.PI;
      const wave=(.16*Math.sin(a*3-t*1.7+nativeLane*.22)+.07*Math.sin(a*5+t*1.1))*.368;
      const x=Math.cos(a),y=Math.cos(-.3)*Math.sin(a)-Math.sin(-.3)*offset,z=Math.sin(-.3)*Math.sin(a)+Math.cos(-.3)*offset;
      const scale=base*(1+wave)/Math.hypot(x,y,z),px=x*scale,py=y*scale,pz=z*scale;
      const depthZ=py*Math.sin(.3)+pz*Math.cos(.3),depth=(depthZ/radius+1)/2;
      const fill=option.inner+(1-option.inner)*u;
      dots.push({x:32+px*fill,y:32-(py*Math.cos(.3)-pz*Math.sin(.3))*fill,z:depthZ,
        radius:Math.max(.3,(1.0516+1.6252*depth)*(1-.25*edge)*size)*option.dotScale,alpha:.4+.6*depth});
    }
  }
  return dots.sort((a,b)=>a.z-b.z);
}
function orbColor(dot,t,dark){
  const angle=Math.atan2(dot.y-32,dot.x-32),position=angle/(2*Math.PI)+t*.014;
  const p=(position-Math.floor(position))*opal.length,i=Math.floor(p),f=p-i;
  const glint=Math.pow(Math.max(0,Math.cos(angle+t*.13)),16),pearl=dark?[.80,.84,.89]:[.31,.35,.42],highlight=dark?[1,1,1]:[.68,.73,.78];
  return pearl.map((base,c)=>{const tint=opal[i][c]+(opal[(i+1)%opal.length][c]-opal[i][c])*f,lit=base+(tint-base)*(.3+.6*glint);return Math.round((lit+(highlight[c]-lit)*glint*.5)*255);});
}
