// SPDX-License-Identifier: GPL-3.0-or-later
// Real-HID mouse driver and read-only window probe for the disposable guest (tests/e2e/compositor-dnd.sh). Posts events at
// kCGHIDEventTap and reads SkyLight window bounds, transform, screen rectangle and alpha, and the window list.
// usage: compositor-dnd-hid [--wid N]... [--msg PATH] [--trace-every K] OP...
//  OPS: pos | move X Y | down X Y [B] | up X Y [B] | drag X Y STEPS DELAYMS [B] | click X Y [B] [N] | sleep MS
//       probe LABEL (one json line per --wid) | wins LABEL [MINLAYER] (on-screen window list at or above that layer, one json line)
//       sh COMMAND | flags cmd,opt,shift,ctrl | noflags | key CODE | state LABEL (runs `PATH msg state`) | watch TOTALMS EVERYMS LABEL
// Derived from the guest probe written for lane interact (hidprobe); no third-party source.
#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
typedef int (*MainConn)(void);
typedef CGError (*GetBounds)(int,uint32_t,CGRect*);
typedef CGError (*GetXform)(int,uint32_t,CGAffineTransform*);
typedef CGError (*GetScreen)(int,uint32_t,CGRect*);
typedef CGError (*GetAlpha)(int,uint32_t,float*);
static MainConn mainConn;static GetBounds sbounds;static GetXform sxform;static GetScreen sscreen;static GetAlpha salpha;
static uint32_t wids[16];static int nwids;static const char *msgPath;static int trace;static int traceEvery=4;static CGEventFlags curFlags;
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9;}
static double t0;
static CGPoint cursor(void){CGEventRef e=CGEventCreate(NULL);CGPoint p=CGEventGetLocation(e);CFRelease(e);return p;}
static void probe(const char *label){
  CGPoint c=cursor();
  for(int i=0;i<nwids;i++){
    uint32_t w=wids[i];CGRect b={0},s={0};CGAffineTransform t=CGAffineTransformIdentity;float a=-1;
    CGError eb=sbounds?sbounds(mainConn(),w,&b):-1,et=sxform?sxform(mainConn(),w,&t):-1,es=sscreen?sscreen(mainConn(),w,&s):-1;if(salpha)salpha(mainConn(),w,&a);
    CGRect cg={0};int on=0;
    CFArrayRef arr=CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,w);
    if(arr&&CFArrayGetCount(arr)==1){CFDictionaryRef d=CFArrayGetValueAtIndex(arr,0);CFDictionaryRef bd=CFDictionaryGetValue(d,kCGWindowBounds);if(bd)CGRectMakeWithDictionaryRepresentation(bd,&cg);
      CFBooleanRef o=CFDictionaryGetValue(d,kCGWindowIsOnscreen);on=o&&CFBooleanGetValue(o);}
    if(arr)CFRelease(arr);
    printf("{\"t\":%.3f,\"label\":\"%s\",\"cursor\":[%.1f,%.1f],\"wid\":%u,\"native\":[%.1f,%.1f,%.1f,%.1f],\"xf\":[%.4f,%.4f,%.4f,%.4f,%.2f,%.2f],\"screen\":[%.1f,%.1f,%.1f,%.1f],\"cglist\":[%.1f,%.1f,%.1f,%.1f],\"onscreen\":%d,\"alpha\":%.2f,\"err\":[%d,%d,%d]}\n",
      now()-t0,label,c.x,c.y,w,b.origin.x,b.origin.y,b.size.width,b.size.height,t.a,t.b,t.c,t.d,t.tx,t.ty,s.origin.x,s.origin.y,s.size.width,s.size.height,cg.origin.x,cg.origin.y,cg.size.width,cg.size.height,on,a,eb,et,es);
  }
  if(!nwids)printf("{\"t\":%.3f,\"label\":\"%s\",\"cursor\":[%.1f,%.1f]}\n",now()-t0,label,c.x,c.y);
  fflush(stdout);
}
static void wins(const char *label,int minlayer){
  CFArrayRef arr=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID);
  printf("{\"t\":%.3f,\"label\":\"%s\",\"wins\":[",now()-t0,label);int first=1;
  for(CFIndex i=0;arr&&i<CFArrayGetCount(arr);i++){CFDictionaryRef d=CFArrayGetValueAtIndex(arr,i);
    int layer=0;CFNumberRef ln=CFDictionaryGetValue(d,kCGWindowLayer);if(ln)CFNumberGetValue(ln,kCFNumberIntType,&layer);
    if(layer<minlayer)continue;
    int num=0,pid=0;double al=1;CFNumberRef n=CFDictionaryGetValue(d,kCGWindowNumber);if(n)CFNumberGetValue(n,kCFNumberIntType,&num);
    n=CFDictionaryGetValue(d,kCGWindowOwnerPID);if(n)CFNumberGetValue(n,kCFNumberIntType,&pid);
    n=CFDictionaryGetValue(d,kCGWindowAlpha);if(n)CFNumberGetValue(n,kCFNumberDoubleType,&al);
    char owner[128]="",name[160]="";CFStringRef o=CFDictionaryGetValue(d,kCGWindowOwnerName);if(o)CFStringGetCString(o,owner,sizeof owner,kCFStringEncodingUTF8);
    CFStringRef nm=CFDictionaryGetValue(d,kCGWindowName);if(nm)CFStringGetCString(nm,name,sizeof name,kCFStringEncodingUTF8);
    for(char *c=name;*c;c++)if(*c=='"'||*c=='\\')*c=' ';
    CGRect b={0};CFDictionaryRef bd=CFDictionaryGetValue(d,kCGWindowBounds);if(bd)CGRectMakeWithDictionaryRepresentation(bd,&b);
    printf("%s{\"id\":%d,\"pid\":%d,\"owner\":\"%s\",\"name\":\"%s\",\"layer\":%d,\"b\":[%.1f,%.1f,%.1f,%.1f],\"alpha\":%.2f}",first?"":",",num,pid,owner,name,layer,b.origin.x,b.origin.y,b.size.width,b.size.height,al);first=0;}
  printf("]}\n");fflush(stdout);if(arr)CFRelease(arr);
}
static void post(CGEventType type,CGPoint p,int button,int clickState){
  CGMouseButton b=button==0?kCGMouseButtonLeft:button==1?kCGMouseButtonRight:kCGMouseButtonCenter;
  CGEventRef e=CGEventCreateMouseEvent(NULL,type,p,b);
  CGEventSetIntegerValueField(e,kCGMouseEventClickState,clickState);
  CGEventSetFlags(e,curFlags);
  CGEventPost(kCGHIDEventTap,e);CFRelease(e);
}
static CGEventType downT(int b){return b==0?kCGEventLeftMouseDown:b==1?kCGEventRightMouseDown:kCGEventOtherMouseDown;}
static CGEventType upT(int b){return b==0?kCGEventLeftMouseUp:b==1?kCGEventRightMouseUp:kCGEventOtherMouseUp;}
static CGEventType dragT(int b){return b==0?kCGEventLeftMouseDragged:b==1?kCGEventRightMouseDragged:kCGEventOtherMouseDragged;}
static void sleepms(double ms){usleep((useconds_t)(ms*1000));}
static void watch(double total,double every,const char *label){
  double end=now()+total/1000.0;char last[512]="";
  while(now()<end){
    for(int i=0;i<nwids;i++){
      uint32_t w=wids[i];CGRect cg={0};int on=0;CFArrayRef arr=CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,w);
      if(arr&&CFArrayGetCount(arr)==1){CFDictionaryRef d=CFArrayGetValueAtIndex(arr,0);CFDictionaryRef bd=CFDictionaryGetValue(d,kCGWindowBounds);if(bd)CGRectMakeWithDictionaryRepresentation(bd,&cg);CFBooleanRef o=CFDictionaryGetValue(d,kCGWindowIsOnscreen);on=o&&CFBooleanGetValue(o);}
      if(arr)CFRelease(arr);
      float a=-1;if(salpha)salpha(mainConn(),w,&a);
      char cur[512];snprintf(cur,sizeof cur,"%u %.1f %.1f %.1f %.1f %d %.2f",w,cg.origin.x,cg.origin.y,cg.size.width,cg.size.height,on,a);
      if(i==0&&strcmp(cur,last)){strcpy(last,cur);printf("{\"t\":%.3f,\"label\":\"%s\",\"watch\":\"%s\"}\n",now()-t0,label,cur);fflush(stdout);}
      else if(i>0){char key[64];(void)key;}
    }
    sleepms(every);
  }
}
int main(int argc,char **argv){
  void *h=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW);
  if(h){mainConn=dlsym(h,"SLSMainConnectionID");sbounds=dlsym(h,"SLSGetWindowBounds");sxform=dlsym(h,"SLSGetWindowTransform");sscreen=dlsym(h,"SLSGetScreenRectForWindow");salpha=dlsym(h,"SLSGetWindowAlpha");}
  t0=now();
  int i=1;
  for(;i<argc;i++){
    if(!strcmp(argv[i],"--wid")&&i+1<argc&&nwids<16)wids[nwids++]=(uint32_t)atoi(argv[++i]);
    else if(!strcmp(argv[i],"--msg")&&i+1<argc)msgPath=argv[++i];
    else if(!strcmp(argv[i],"--trace"))trace=1;
    else if(!strcmp(argv[i],"--trace-every")&&i+1<argc){trace=1;traceEvery=atoi(argv[++i]);}
    else break;
  }
  for(;i<argc;i++){
    const char *op=argv[i];
    if(!strcmp(op,"pos")){CGPoint c=cursor();printf("{\"cursor\":[%.1f,%.1f]}\n",c.x,c.y);}
    else if(!strcmp(op,"move")){CGPoint p=CGPointMake(atof(argv[i+1]),atof(argv[i+2]));i+=2;post(kCGEventMouseMoved,p,0,0);sleepms(30);}
    else if(!strcmp(op,"down")||!strcmp(op,"up")){int d=!strcmp(op,"down");CGPoint p=CGPointMake(atof(argv[i+1]),atof(argv[i+2]));i+=2;int b=0;if(i+1<argc&&argv[i+1][0]>='0'&&argv[i+1][0]<='2'&&strlen(argv[i+1])==1)b=atoi(argv[++i]);post(d?downT(b):upT(b),p,b,1);sleepms(30);}
    else if(!strcmp(op,"drag")){
      CGPoint to=CGPointMake(atof(argv[i+1]),atof(argv[i+2]));int steps=atoi(argv[i+3]);double dl=atof(argv[i+4]);i+=4;int b=0;
      if(i+1<argc&&strlen(argv[i+1])==1&&argv[i+1][0]>='0'&&argv[i+1][0]<='2')b=atoi(argv[++i]);
      CGPoint from=cursor();
      for(int s=1;s<=steps;s++){CGPoint p=CGPointMake(from.x+(to.x-from.x)*s/steps,from.y+(to.y-from.y)*s/steps);post(dragT(b),p,b,1);sleepms(dl);if(trace&&(s%traceEvery==0||s==steps)){char l[32];snprintf(l,sizeof l,"drag%d",s);probe(l);}}
    }
    else if(!strcmp(op,"click")){CGPoint p=CGPointMake(atof(argv[i+1]),atof(argv[i+2]));i+=2;int b=0,n=1;if(i+1<argc&&strlen(argv[i+1])==1&&argv[i+1][0]>='0'&&argv[i+1][0]<='2')b=atoi(argv[++i]);if(i+1<argc&&strlen(argv[i+1])==1&&argv[i+1][0]>='1'&&argv[i+1][0]<='3')n=atoi(argv[++i]);
      post(kCGEventMouseMoved,p,0,0);sleepms(60);for(int k=1;k<=n;k++){post(downT(b),p,b,k);sleepms(40);post(upT(b),p,b,k);sleepms(60);}}
    else if(!strcmp(op,"wins")){const char *l=argv[++i];int ml=0;if(i+1<argc&&(argv[i+1][0]=='-'||(argv[i+1][0]>='0'&&argv[i+1][0]<='9')))ml=atoi(argv[++i]);wins(l,ml);}
    else if(!strcmp(op,"sh")){const char *c=argv[++i];int rc=system(c);if(rc)fprintf(stderr,"sh rc=%d\n",rc);}
    else if(!strcmp(op,"sleep")){sleepms(atof(argv[++i]));}
    else if(!strcmp(op,"probe")){probe(argv[++i]);}
    else if(!strcmp(op,"key")){int code=atoi(argv[++i]);for(int d=1;d>=0;d--){CGEventRef e=CGEventCreateKeyboardEvent(NULL,(CGKeyCode)code,d);CGEventSetFlags(e,curFlags);CGEventPost(kCGHIDEventTap,e);CFRelease(e);sleepms(40);}}
    else if(!strcmp(op,"watch")){double tot=atof(argv[i+1]),ev=atof(argv[i+2]);const char *l=argv[i+3];i+=3;watch(tot,ev,l);}
    else if(!strcmp(op,"flags")){curFlags=0;char *s=strdup(argv[++i]);for(char *t=strtok(s,",");t;t=strtok(NULL,",")){if(!strcmp(t,"cmd"))curFlags|=kCGEventFlagMaskCommand;if(!strcmp(t,"opt"))curFlags|=kCGEventFlagMaskAlternate;if(!strcmp(t,"shift"))curFlags|=kCGEventFlagMaskShift;if(!strcmp(t,"ctrl"))curFlags|=kCGEventFlagMaskControl;}free(s);}
    else if(!strcmp(op,"noflags"))curFlags=0;
    else if(!strcmp(op,"state")){const char *label=argv[++i];if(msgPath){char cmd[1024];snprintf(cmd,sizeof cmd,"%s msg state 2>&1",msgPath);FILE *f=popen(cmd,"r");if(f){char *line=NULL;size_t cap=0;ssize_t n;printf("{\"t\":%.3f,\"label\":\"%s\",\"state\":",now()-t0,label);int first=1;while((n=getline(&line,&cap,f))>0){while(n>0&&(line[n-1]=='\n'))line[--n]=0;if(!first)printf(" ");fputs(line,stdout);first=0;}printf("}\n");free(line);pclose(f);}}fflush(stdout);}
    else {fprintf(stderr,"unknown op %s\n",op);return 2;}
  }
  return 0;
}
