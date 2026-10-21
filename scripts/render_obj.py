# Flat-shaded, depth-buffered preview of OBJ files written by
# scripts/preview_case.rb (hard edges drawn, soft edges hidden, back faces red).
# Usage: python3 scripts/render_obj.py out.png ELEV AZIM file1.obj [file2.obj ...]
# Env: ZOOM="x,y,z,radius" to zoom on a point; SMOOTH=1 for smooth shading.
import os
import sys, numpy as np
from PIL import Image, ImageDraw
def load(path):
    V=[];F=[];holes={};soft=set()
    for line in open(path):
        t=line.split()
        if not t: continue
        if t[0]=='v': V.append([float(x) for x in t[1:4]])
        elif t[0]=='f': F.append([int(x)-1 for x in t[1:]])
        elif t[0]=='#hole': holes.setdefault(len(F)-1,[]).append([int(x)-1 for x in t[1:]])
        elif t[0]=='#soft': a,b=int(t[1])-1,int(t[2])-1; soft.add((min(a,b),max(a,b)))
    return np.array(V),F,holes,soft


def newell(pts):
    n=np.zeros(3)
    for i in range(len(pts)):
        a=pts[i];b=pts[(i+1)%len(pts)]
        n+=np.array([(a[1]-b[1])*(a[2]+b[2]),(a[2]-b[2])*(a[0]+b[0]),(a[0]-b[0])*(a[1]+b[1])])
    return n

def view_matrix(elev, azim):
    e=np.radians(elev); a=np.radians(azim)
    d=np.array([np.cos(e)*np.cos(a), np.cos(e)*np.sin(a), np.sin(e)])  # toward camera
    up=np.array([0,0,1.0]); r=np.cross(up,d); r/=np.linalg.norm(r); u=np.cross(d,r)
    return np.array([r,u,d])

def render_one(path, W=420, elev=28, azim=-55, title=''):
    V,F,holes,soft=load(path)
    R=view_matrix(elev,azim)
    P=V@R.T
    zoom=os.environ.get('ZOOM')
    if zoom:
        zx,zy,zz,zr=[float(t) for t in zoom.split(',')]
        cc=np.array([zx,zy,zz])@R.T; c=cc; s=W/(2*zr)
    else:
        mn=P.min(0); mx=P.max(0); c=(mn+mx)/2; s=0.85*W/max(mx[0]-mn[0],mx[1]-mn[1])
    X=(P[:,0]-c[0])*s+W/2; Y=W/2-(P[:,1]-c[1])*s; Z=P[:,2]
    zbuf=np.full((W,W),-1e18); img=np.ones((W,W,3))
    light=np.array([0.3,-0.5,0.85]); light/=np.linalg.norm(light)
    yy,xx=np.mgrid[0:W,0:W]
    fn=[]
    for f in F:
        nn=newell(V[f]); l=np.linalg.norm(nn); fn.append(nn/l if l>0 else nn)
    vfaces={}
    for fi,f in enumerate(F):
        for a in f: vfaces.setdefault(a,[]).append(fi)
    # faces connected through soft edges form smoothing groups
    parent=list(range(len(F)))
    def find(x):
        while parent[x]!=x: parent[x]=parent[parent[x]]; x=parent[x]
        return x
    ef={}
    for fi,f in enumerate(F):
        for i in range(len(f)):
            k=(min(f[i],f[(i+1)%len(f)]),max(f[i],f[(i+1)%len(f)]))
            ef.setdefault(k,[]).append(fi)
    for k,l in ef.items():
        if k in soft and len(l)==2: parent[find(l[0])]=find(l[1])
    def vnorm(fi,a):
        g=find(fi); acc=np.zeros(3)
        for o in vfaces[a]:
            if find(o)==g: acc+=fn[o]
        l=np.linalg.norm(acc); return acc/l if l>0 else fn[fi]
    smooth=os.environ.get('SMOOTH') is not None
    def fill_polygon(loops, nrm, col):
        # Flat fill of a planar polygon with holes (even-odd rule), depth
        # from its plane (orthographic view).
        xs=np.concatenate([X[lp] for lp in loops]); ys=np.concatenate([Y[lp] for lp in loops])
        x0=max(int(np.floor(xs.min())),0);x1=min(int(np.ceil(xs.max())),W-1)
        y0=max(int(np.floor(ys.min())),0);y1=min(int(np.ceil(ys.max())),W-1)
        if x1<x0 or y1<y0: return
        nv=R@nrm
        if abs(nv[2])<1e-9: return
        px=xx[y0:y1+1,x0:x1+1]+0.5;py=yy[y0:y1+1,x0:x1+1]+0.5
        inside=np.zeros(px.shape,bool)
        for lp in loops:
            for i in range(len(lp)):
                a,b=lp[i],lp[(i+1)%len(lp)]
                xa,ya,xb,yb=X[a],Y[a],X[b],Y[b]
                if ya==yb: continue
                cr=((ya>py)!=(yb>py))&(px<xa+(py-ya)*(xb-xa)/(yb-ya))
                inside^=cr
        p0=P[loops[0][0]]
        vx=(px-W/2)/s+c[0]; vy=(W/2-py)/s+c[1]
        zz=(nv@p0-nv[0]*vx-nv[1]*vy)/nv[2]
        zb=zbuf[y0:y1+1,x0:x1+1]
        upd=inside&(zz>zb)
        zb[upd]=zz[upd]
        img[y0:y1+1,x0:x1+1][upd]=col
    for fi,f in enumerate(F):
        if not smooth:
            nrm=newell(V[f]); l=np.linalg.norm(nrm)
            if l==0: continue
            nrm/=l
            back=(nrm@R[2])<0
            col=np.array([0.86,0.80,0.68])*(0.3+0.7*abs(nrm@light)) if not back else np.array([0.95,0.1,0.1])
            fill_polygon([f]+holes.get(fi,[]), nrm, col)
            continue
        if fi in holes: continue  # smooth mode: triangle fans would cover the hole
        nrm=newell(V[f]); l=np.linalg.norm(nrm)
        if l==0: continue
        nrm/=l
        sh=0.3+0.7*abs(nrm@light)
        back = (nrm@R[2])<0
        col=np.array([0.86,0.80,0.68])*sh if not back else np.array([0.95,0.1,0.1])
        shv={a:(0.3+0.7*abs(vnorm(fi,a)@light)) if smooth else sh for a in f}
        base=np.array([0.86,0.80,0.68]) if not back else np.array([0.95,0.1,0.1])
        for i in range(1,len(f)-1):
            t=[f[0],f[i],f[i+1]]
            x=X[t];y=Y[t];z=Z[t]
            x0=max(int(np.floor(x.min())),0);x1=min(int(np.ceil(x.max())),W-1)
            y0=max(int(np.floor(y.min())),0);y1=min(int(np.ceil(y.max())),W-1)
            if x1<x0 or y1<y0: continue
            px=xx[y0:y1+1,x0:x1+1]+0.5;py=yy[y0:y1+1,x0:x1+1]+0.5
            d=(y[1]-y[2])*(x[0]-x[2])+(x[2]-x[1])*(y[0]-y[2])
            if abs(d)<1e-12: continue
            w0=((y[1]-y[2])*(px-x[2])+(x[2]-x[1])*(py-y[2]))/d
            w1=((y[2]-y[0])*(px-x[2])+(x[0]-x[2])*(py-y[2]))/d
            w2=1-w0-w1
            m=(w0>=-1e-6)&(w1>=-1e-6)&(w2>=-1e-6)
            zz=w0*z[0]+w1*z[1]+w2*z[2]
            zb=zbuf[y0:y1+1,x0:x1+1]
            upd=m&(zz>zb)
            zb[upd]=zz[upd]
            shp=w0*shv[t[0]]+w1*shv[t[1]]+w2*shv[t[2]]
            if back: shp=np.ones_like(shp)
            img[y0:y1+1,x0:x1+1][upd]=base[None,:]*shp[upd][:,None]
    # hard edges with depth test
    eps=(Z.max()-Z.min())*0.004+1e-9
    edges=set()
    for f in F+[lp for l in holes.values() for lp in l]:
        for i in range(len(f)):
            a,b=f[i],f[(i+1)%len(f)]
            k=(min(a,b),max(a,b))
            if k not in soft: edges.add(k)
    for a,b in edges:
        n=int(max(abs(X[a]-X[b]),abs(Y[a]-Y[b]))*2)+2
        t=np.linspace(0,1,n)
        ex=X[a]+(X[b]-X[a])*t; ey=Y[a]+(Y[b]-Y[a])*t; ez=Z[a]+(Z[b]-Z[a])*t
        ix=np.clip(ex.astype(int),0,W-1); iy=np.clip(ey.astype(int),0,W-1)
        vis=ez>=zbuf[iy,ix]-eps
        img[iy[vis],ix[vis]]=[0.1,0.1,0.1]
    im=Image.fromarray((img*255).astype(np.uint8))
    ImageDraw.Draw(im).text((6,4),title,fill=(0,0,0))
    return im

if __name__=='__main__':
    out=sys.argv[1]; elev=float(sys.argv[2]); azim=float(sys.argv[3]); paths=sys.argv[4:]
    ims=[render_one(p,elev=elev,azim=azim,title=p.split('/')[-1][:-4]) for p in paths]
    cols=min(3,len(ims)); rows=(len(ims)+cols-1)//cols; W=ims[0].size[0]
    sheet=Image.new('RGB',(cols*W,rows*W),'white')
    for i,im in enumerate(ims): sheet.paste(im,((i%cols)*W,(i//cols)*W))
    sheet.save(out)
