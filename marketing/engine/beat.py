# Synth beat (no copyright). usage: python3 beat.py out.wav DURATION [seed] [cuts comma-separated seconds]
import sys, wave, numpy as np
out=sys.argv[1]; D=float(sys.argv[2]); seed=int(sys.argv[3]) if len(sys.argv)>3 else 1
cuts=[float(x) for x in sys.argv[4].split(',')] if len(sys.argv)>4 and sys.argv[4] else []
SR=44100; N=int(SR*D); L=np.zeros(N); rng=np.random.default_rng(seed)
def add(t,s,g=1.0):
    i=int(t*SR); n=min(len(s),N-i)
    if n>0 and i>=0: L[i:i+n]+=s[:n]*g
tt=lambda d: np.arange(int(d*SR))/SR
def kick(g=1,d=.35):
    t=tt(d); f=45+120*np.exp(-t*30); return np.sin(2*np.pi*np.cumsum(f)/SR)*np.exp(-t*9)*g
def noise(d,dec):
    t=tt(d); n=np.diff(np.concatenate([[0],rng.standard_normal(len(t))])); return n*np.exp(-t*dec)
def tone(f,d,dec=6,harm=(1,.5,.25)):
    t=tt(d); return sum(a*np.sin(2*np.pi*f*(k+1)*t) for k,a in enumerate(harm))*np.exp(-t*dec)*np.minimum(1,t*400)
def bass(f,d):
    t=tt(d); return sum(np.sin(2*np.pi*f*k*t)/k for k in range(1,8))*np.minimum(1,t*200)*np.exp(-t*3)*.35
keys=[[55.0,43.65,65.41,49.0],[49.0,58.27,43.65,51.91],[41.2,49.0,55.0,36.71]]
notes=keys[seed%len(keys)]; bpm=[124,128,120][seed%3]; B=60/bpm
k=0
while k*B<D-.4:
    t=k*B; add(t,kick(1.0 if t>1 else .8))
    if k%2==1: add(t,noise(.22,18)*.5+np.pad(tone(190,.22,25,(1,)),(0,0))*.6,.5)
    add(t+B/2,noise(.05,80)*.25); add(t+B/4,noise(.05,80)*.1); add(t+3*B/4,noise(.05,80)*.1)
    add(t+B/2,bass(notes[int(k//4)%4],B*.48)); k+=1
for c in cuts:  # whoosh + impact on each scene change
    t=tt(.35); f=300+1500*(t/.35)**2; add(c-.35,np.sin(2*np.pi*np.cumsum(f)/SR)*.08*(t/.35)+rng.standard_normal(len(t))*(t/.35)**2*.12)
    add(c,kick(1.3,.6),.8)
for f in [261.63,329.63,392,523.25]: add(max(0,D-2.6),tone(f,2.4,1.3,(1,.4,.2)),.1)
L=np.tanh(L*1.1); m=int(.4*SR); L[-m:]*=np.linspace(1,0,m); L=L/np.max(np.abs(L))*.89
st=(np.stack([L,L],1)*32767).astype(np.int16)
with wave.open(out,'wb') as w: w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(st.tobytes())
