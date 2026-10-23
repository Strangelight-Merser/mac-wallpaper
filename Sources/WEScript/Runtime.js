// Math/color API and timer cancellation conventions ported from linux-wallpaperengine
// Scripting/{Modules,EngineObject.cpp,resources/builtins.js} (GPLv3).
// Vector operations use receiver-first arithmetic, correcting upstream adapter defects.
(function (bridge) {
    'use strict';
    const keys = ['x', 'y', 'z', 'w'];
    function vectorClass(n) {
        class Vector {
            constructor(...args) {
                for (let i = 0; i < n; i++) {
                    this[keys[i]] = args.length === 1
                        ? (typeof args[0] === 'object' ? Number(args[0][keys[i]] || 0) : Number(args[0]))
                        : Number(args[i] || 0);
                }
            }
            map(f) { return new this.constructor(...keys.slice(0, n).map((k, i) => f(this[k], k, i))); }
            zip(v, f) { return this.map((x, k) => f(x, typeof v === 'number' ? v : v[k])); }
            copy() { return new this.constructor(this); }
            add(v) { return this.zip(v, (a,b) => a+b); }
            subtract(v) { return this.zip(v, (a,b) => a-b); }
            multiply(v) { return this.zip(v, (a,b) => a*b); }
            divide(v) { return this.zip(v, (a,b) => a/b); }
            dot(v) { return keys.slice(0,n).reduce((s,k) => s + this[k]*v[k], 0); }
            lengthSqr() { return this.dot(this); }
            length() { return Math.sqrt(this.lengthSqr()); }
            normalize() { const l = this.length(); return l ? this.divide(l) : this.copy(); }
            mix(v,t) { return this.multiply(1-t).add(v.multiply ? v.multiply(t) : new this.constructor(v).multiply(t)); }
            min(v) { return this.zip(v, Math.min); }
            max(v) { return this.zip(v, Math.max); }
            abs() { return this.map(Math.abs); }
            sign() { return this.map(Math.sign); }
            round() { return this.map(Math.round); }
            floor() { return this.map(Math.floor); }
            ceil() { return this.map(Math.ceil); }
            equals(v) { return keys.slice(0,n).every(k => this[k] === v[k]); }
            reflect(normal) { return this.subtract(normal.multiply(2*this.dot(normal))); }
            toString() { return keys.slice(0,n).map(k => this[k]).join(' '); }
        }
        for (let i=0;i<n;i++) Object.defineProperty(Vector.prototype, 'rgba'[i], {
            get() { return this[keys[i]]; }, set(v) { this[keys[i]]=v; }
        });
        return Vector;
    }
    const Vec2 = vectorClass(2), Vec3 = vectorClass(3), Vec4 = vectorClass(4);
    Vec3.prototype.cross = function(v) {
        return new Vec3(this.y*v.z-this.z*v.y, this.z*v.x-this.x*v.z, this.x*v.y-this.y*v.x);
    };
    Object.assign(globalThis, {Vec2, Vec3, Vec4});
    const WEMath = {
        PI: Math.PI, deg2rad: Math.PI/180, rad2deg: 180/Math.PI,
        clamp: (x,a,b) => Math.min(b,Math.max(a,x)),
        mix: (a,b,t) => a*(1-t)+b*t,
        smoothStep(a,b,x) { const t=WEMath.clamp((x-a)/(b-a),0,1); return t*t*(3-2*t); }
    };
    // Normalized HSV (hue 0…1, as WE documents and real scripts use; the reference module used degrees).
    const WEColor = {
        hsv2rgb(v) {
            const h=((v.x%1)+1)%1*6, i=Math.floor(h), f=h-i;
            const p=v.z*(1-v.y), q=v.z*(1-v.y*f), t=v.z*(1-v.y*(1-f));
            return new Vec3(...[[v.z,t,p],[q,v.z,p],[p,v.z,t],[p,q,v.z],[t,p,v.z],[v.z,p,q]][i]);
        },
        rgb2hsv(v) {
            const max=Math.max(v.x,v.y,v.z), min=Math.min(v.x,v.y,v.z), d=max-min;
            let h=0;
            if(d) h=60*(max===v.x ? (v.y-v.z)/d : max===v.y ? (v.z-v.x)/d+2 : (v.x-v.y)/d+4);
            return new Vec3((h+360)%360/360,max ? d/max : 0,max);
        },
        normalizeColor: v => new Vec3(v).divide(255),
        expandColor: v => new Vec3(v).multiply(255),
        hsv: (h,s,v) => WEColor.hsv2rgb(new Vec3(h,s,v))
    };
    const modules = {WEMath,WEColor,WEVector:{Vec2,Vec3,Vec4}};
    let active = null;
    const scripts = [], layers = new Map(), timers = new Map(), audioBuffers = new Map(), warned = new Set();
    let timerID=0, storage={};
    const call = (op,id=0,key='',value=null) => bridge(op,id,key,value);
    function warn(name) {
        if (!warned.has(name)) { warned.add(name); call('log',0,'warn','Unsupported SceneScript API: '+name); }
    }
    function fail(record,error) {
        if(record.disabled) return;
        record.disabled=true;
        call('log',0,'error',record.label+': '+String(error));
        for(const [id,t] of timers) if(t.owner===record) timers.delete(id);
    }
    function invoke(record,fn,args) {
        if(record.disabled || typeof fn!=='function') return;
        const previous=active; active=record;
        try { return fn(...args); } catch(e) { fail(record,e); }
        finally { active=previous; }
    }
    function material(id,prefix,pass=0) {
        const path=prefix+'passes['+pass+'].constantshadervalues.';
        return new Proxy({}, {
            get: (_,key) => typeof key==='string' ? call('get',id,path+key) : undefined,
            set: (_,key,value) => { call('set',id,path+key,value); return true; }
        });
    }
    function animation(id) {
        if(!call('hasAnimation',id)) return null;
        return {
            play: () => call('animation',id,'play'), pause: () => call('animation',id,'pause'),
            stop: () => call('animation',id,'stop'), isPlaying: () => call('animation',id,'isPlaying'),
            getFrame: () => call('animation',id,'frame'), setFrame: v => call('animation',id,'frame',v),
            get frameCount() { return call('animation',id,'frameCount'); },
            get rate() { return call('animation',id,'rate'); },
            set rate(v) { call('animation',id,'rate',v); }
        };
    }
    function object(id,prefix='') {
        const cacheKey=id+':'+prefix;
        if(layers.has(cacheKey)) return layers.get(cacheKey);
        let anim;
        const target={
            getParent: () => { const p=call('parent',id); return p===null ? null : object(p); },
            getTransformMatrix: () => ({m:call('matrix',id)}),
            getAnimation: () => anim || (anim=animation(id)),
            getTextureAnimation: () => anim || (anim=animation(id)),
            getEffect: name => {
                const index=typeof name==='number' ? name : call('effect',id,String(name));
                return index===null ? null : object(id,'effects['+index+'].');
            },
            getMaterial: pass => material(id,prefix,pass),
            play() { warn('layer.play'); }, stop() { warn('layer.stop'); },
            pause() { warn('layer.pause'); }, isPlaying() { warn('layer.isPlaying'); return false; }
        };
        const proxy=new Proxy(target, {
            get(t,key) {
                if(key in t) return t[key];
                if(key==='id') return id;
                if(key==='name') return call('name',id);
                if(typeof key!=='string') return undefined;
                return call('get',id,prefix+key);
            },
            set(t,key,value) { call('set',id,prefix+key,value); return true; }
        });
        layers.set(cacheKey,proxy); return proxy;
    }
    function layerID(value) {
        return typeof value==='string' ? call('find',0,value) : typeof value==='number' ? value : value && value.id;
    }
    globalThis.thisScene=new Proxy({
        getLayer(value) { const id=layerID(value); return id==null ? null : object(id); },
        getLayerIndex(value) { return call('index',layerID(value) ?? -1); },
        getLayerCount() { return call('count'); },
        sortLayer(value,index) { const id=layerID(value); if(id!=null) call('sort',id,'',index); },
        createLayer() { warn('thisScene.createLayer'); return null; },
        destroyLayer() { warn('thisScene.destroyLayer'); }
    }, {
        get: (t,k) => k in t ? t[k] : call('sceneGet',0,String(k)),
        set: (t,k,v) => { call('sceneSet',0,String(k),v); return true; }
    });
    function timer(fn,ms,repeat) {
        if(typeof fn!=='function') throw new TypeError('Timer callback must be a function');
        const id=++timerID, delay=Math.max(0,Number(ms)||0)/1000;
        timers.set(id,{fn,delay,due:engine.runtime+delay,repeat,owner:active});
        const cancel=()=>timers.delete(id);
        cancel.valueOf=()=>id;
        return cancel;
    }
    globalThis.engine={
        frametime:0,runtime:0,timeOfDay:0,canvasSize:new Vec2(0),screenResolution:new Vec2(0),userProperties:{},
        AUDIO_RESOLUTION_16:16,AUDIO_RESOLUTION_32:32,AUDIO_RESOLUTION_64:64,
        setTimeout:(fn,ms)=>timer(fn,ms,false),setInterval:(fn,ms)=>timer(fn,ms,true),
        clearTimeout: id=>timers.delete(Number(id)),clearInterval: id=>timers.delete(Number(id)),
        registerAudioBuffers(n) {
            if(![16,32,64].includes(n)) throw new RangeError('Audio resolution must be 16, 32 or 64');
            if(!audioBuffers.has(n)) audioBuffers.set(n,{left:Array(n).fill(0),right:Array(n).fill(0),average:Array(n).fill(0)});
            return audioBuffers.get(n);
        },
        registerAsset() { warn('engine.registerAsset'); return null; },
        isDesktopDevice:()=>true,isWallpaper:()=>true,isScreensaver:()=>false,isRunningInEditor:()=>false
    };
    globalThis.shared={};
    globalThis.input={cursorWorldPosition:new Vec3(0)};
    globalThis.console=Object.fromEntries(['log','warn','error'].map(level=>[level,(...args)=>call('log',0,level,args.map(String).join(' '))]));
    globalThis.MediaPlaybackEvent={PLAYBACK_STOPPED:0,PLAYBACK_PLAYING:1,PLAYBACK_PAUSED:2};
    function revive(v) {
        if(v && typeof v==='object') {
            if(v.__weVector) return new [null,null,Vec2,Vec3,Vec4][v.__weVector](...v.components);
            for(const k of Object.keys(v)) v[k]=revive(v[k]);
        }
        return v;
    }
    function serialize(v) {
        return JSON.stringify(v, (_,item)=> {
            const n=item instanceof Vec4 ? 4 : item instanceof Vec3 ? 3 : item instanceof Vec2 ? 2 : 0;
            return n ? {__weVector:n,components:keys.slice(0,n).map(k=>item[k])} : item;
        });
    }
    const storageKey=(key,location)=>String(location ?? 0)+':'+String(key);
    globalThis.localStorage={
        LOCATION_GLOBAL:0,LOCATION_SCREEN:1,
        get(key,location) { const v=storage[storageKey(key,location)]; return v===undefined ? null : revive(JSON.parse(serialize(v))); },
        set(key,value,location) { storage[storageKey(key,location)]=revive(JSON.parse(serialize(value))); call('storage',0,'',serialize(storage)); },
        delete(key,location) { delete storage[storageKey(key,location)]; call('storage',0,'',serialize(storage)); },
        clear(location) {
            const prefix=String(location ?? 0)+':';
            for(const k of Object.keys(storage)) if(k.startsWith(prefix)) delete storage[k];
            call('storage',0,'',serialize(storage));
        }
    };
    const RealDate=Date;
    let fixed=null;
    function ClockDate(...args) {
        if(!new.target) return new RealDate(fixed===null ? RealDate.now() : fixed).toString();
        return Reflect.construct(RealDate,args.length ? args : [fixed===null ? RealDate.now() : fixed],new.target);
    }
    ClockDate.prototype=RealDate.prototype;
    Object.setPrototypeOf(ClockDate,RealDate);
    ClockDate.now=()=>fixed===null ? RealDate.now() : fixed;
    globalThis.Date=ClockDate;
    function resolve(record) {
        const values={...record.defaults};
        for(const [key,raw] of Object.entries(record.overrides)) {
            let v=raw;
            if(v && typeof v==='object' && 'value' in v) v=('user' in v && v.user in engine.userProperties) ? engine.userProperties[v.user] : v.value;
            if(record.colors.has(key) && !(v instanceof Vec3)) {
                if(typeof v==='string') v=new Vec3(...v.trim().split(/\s+/).map(Number));
                else if(Array.isArray(v)) v=new Vec3(...v);
                else if(v && typeof v==='object') v=new Vec3(v);
            }
            values[key]=v;
        }
        Object.assign(record.properties,values);
    }
    function builder(record) {
        const b={finish:()=>record.properties};
        for(const kind of ['Checkbox','Slider','Combo','Text','TextInput','Color','File','Directory']) {
            b['add'+kind]=o=> {
                record.defaults[o.name]=o.value===undefined && kind==='Combo' ? o.options?.[0]?.value : o.value;
                if(kind==='Color') record.colors.add(o.name);
                resolve(record); return b;
            };
        }
        return b;
    }
    function commit(record,v) {
        if(!record.disabled && v!==undefined) {
            try { call('set',record.id,record.path,v); record.value=v; }
            catch(e) { fail(record,e); }
        }
    }
    return {
        configure(users,size,clock,saved,screen) {
            engine.userProperties=users; engine.canvasSize=size; engine.screenResolution=screen;
            fixed=clock; storage=revive(JSON.parse(saved));
            const d=new Date(); engine.timeOfDay=(d.getHours()*3600+d.getMinutes()*60+d.getSeconds()+d.getMilliseconds()/1000)/86400;
        },
        add(id,path,factory,overrides,value,label) {
            const r={id,path,value,label,overrides,defaults:{},properties:{},colors:new Set(),disabled:false,exports:{}};
            scripts.push(r); call('set',id,path,value); active=r;
            try {
                resolve(r);
                const match=/^effects\[\d+\]\./.exec(path);
                r.exports=factory(object(id),object(id,match ? match[0] : ''),()=>builder(r),modules);
            } catch(e) { fail(r,e); }
            active=null;
            commit(r,invoke(r,r.exports.init,[value]));
            invoke(r,r.exports.applyUserProperties,[engine.userProperties]);
            if(r.disabled) { call('set',id,path,value); return value; }
            const current=call('get',id,path);
            return current===undefined ? r.value : current;
        },
        tick(dt,time,date,cursor,left,right) {
            engine.frametime=dt; engine.runtime=time; input.cursorWorldPosition=cursor;
            const d=new RealDate(fixed===null ? date : fixed);
            engine.timeOfDay=(d.getHours()*3600+d.getMinutes()*60+d.getSeconds()+d.getMilliseconds()/1000)/86400;
            function sample(a,i,n) {
                if(!a.length) return 0;
                const start=Math.floor(i*a.length/n), end=Math.max(start+1,Math.floor((i+1)*a.length/n));
                let sum=0; for(let j=start;j<end;j++) sum+=a[Math.min(j,a.length-1)];
                return sum/(end-start);
            }
            for(const [n,b] of audioBuffers) for(let i=0;i<n;i++) {
                b.left[i]=sample(left,i,n); b.right[i]=sample(right,i,n); b.average[i]=(b.left[i]+b.right[i])/2;
            }
            // Snapshot: timers created by callbacks wait until the next tick; intervals fire at most once per frame.
            for(const [id,t] of Array.from(timers)) {
                if(!timers.has(id) || t.due>time) continue;
                if(t.repeat) t.due=time+t.delay; else timers.delete(id);
                invoke(t.owner,t.fn,[]);
            }
            for(const r of scripts) if(!r.disabled && typeof r.exports.update==='function') {
                const current=call('get',r.id,r.path);
                commit(r,invoke(r,r.exports.update,[current===undefined ? r.value : current]));
            }
        },
        users(values) {
            engine.userProperties={...engine.userProperties,...values};
            for(const r of scripts) if(!r.disabled) { resolve(r); invoke(r,r.exports.applyUserProperties,[values]); }
        },
        event(name,id,event) {
            if(name.startsWith('cursor')) input.cursorWorldPosition=event.worldPosition;
            for(const r of scripts) if(id===null || r.id===id) invoke(r,r.exports[name],[event]);
        }
    };
})(__weBridge);
