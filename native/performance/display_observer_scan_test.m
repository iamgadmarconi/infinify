// SPDX-License-Identifier: GPL-3.0-or-later
// VM-only equivalence contract for the actual observer scanner. No capture,
// native window getter/setter, permission request or application is invoked.
#import <Foundation/Foundation.h>
#define main DWDisplayObserverProgramMain
#import "display_observer.m"
#undef main
#include <sys/sysctl.h>

static size_t scanCases;
// The original per-pixel implementation is the independent reference for this
// vectorization change, including empty images and inclusive edge semantics.
static MarkerBounds originalScan(const uint8_t *data,size_t width,size_t height,size_t stride) {
    MarkerBounds bounds={.left=width,.top=height};
    for(size_t y=0;y<height;y++){
        const uint8_t *row=data+y*stride;
        for(size_t x=0;x<width;x++){
            const uint8_t *pixel=row+4*x;
            if(pixel[0]>190&&pixel[1]<65&&pixel[2]>190&&pixel[3]>190){
                bounds.left=MIN(bounds.left,x);bounds.right=MAX(bounds.right,x);
                bounds.top=MIN(bounds.top,y);bounds.bottom=MAX(bounds.bottom,y);bounds.count++;
            }
        }
    }
    return bounds;
}
static void compareScan(const uint8_t *data,size_t width,size_t height,size_t stride,const char *pattern) {
    MarkerBounds expected=originalScan(data,width,height,stride),actual=markerBounds(data,width,height,stride);scanCases++;
    if(expected.left!=actual.left||expected.top!=actual.top||expected.right!=actual.right
       ||expected.bottom!=actual.bottom||expected.count!=actual.count){
        fprintf(stderr,"FAIL: %s %zux%zu stride=%zu scalar=[%zu,%zu,%zu,%zu,%zu] neon=[%zu,%zu,%zu,%zu,%zu]\n",
            pattern,width,height,stride,expected.left,expected.top,expected.right,expected.bottom,expected.count,
            actual.left,actual.top,actual.right,actual.bottom,actual.count);exit(1);
    }
}
static uint32_t randomWord(uint32_t *state) { uint32_t value=*state;value^=value<<13;value^=value>>17;value^=value<<5;*state=value;return value; }
static uint8_t *image(size_t width,size_t height,size_t padding,size_t *stride) {
    *stride=width*4+padding;size_t bytes=MAX((size_t)1,*stride*height);
    uint8_t *data=malloc(bytes);if(!data){fputs("image allocation failed\n",stderr);exit(1);}
    // Matching magenta padding makes accidental inclusion of row padding alter
    // counts/bounds. Odd strides also force unaligned loads on following rows.
    for(size_t i=0;i<bytes;i++)data[i]=(i%4==1)?0:255;
    return data;
}
static void patternCases(void) {
    const size_t widths[]={0,1,2,7,15,16,17,23,31,32,33,47,48,49,63,64,65,2056};
    const size_t heights[]={0,1,2,7,17},paddings[]={0,1,3,7,31};
    for(size_t wi=0;wi<sizeof(widths)/sizeof(*widths);wi++)
        for(size_t hi=0;hi<sizeof(heights)/sizeof(*heights);hi++)
            for(size_t pi=0;pi<sizeof(paddings)/sizeof(*paddings);pi++){
                size_t width=widths[wi],height=heights[hi],stride=0;
                uint8_t *data=image(width,height,paddings[pi],&stride);
                for(unsigned pattern=0;pattern<6;pattern++){
                    uint32_t seed=(uint32_t)(0x81425A79u+width*17+height*31+stride*7+pattern);
                    for(size_t y=0;y<height;y++)for(size_t x=0;x<width;x++){
                        uint8_t *pixel=data+y*stride+4*x;BOOL match=NO;
                        switch(pattern){
                            case 0:break; // empty
                            case 1:match=YES;break; // full matching rectangle
                            case 2:match=(x==0||x+1==width||y==0||y+1==height);break;
                            case 3:match=((x+y)%2)==0;break;
                            case 4:match=(x+1==width&&y==0)||(x==0&&y+1==height)||(x%17==5&&y%7==2);break;
                            default:for(unsigned channel=0;channel<4;channel++)pixel[channel]=(uint8_t)randomWord(&seed);continue;
                        }
                        pixel[0]=match?191:190;pixel[1]=match?64:65;pixel[2]=191;pixel[3]=191;
                    }
                    char label[40];snprintf(label,sizeof(label),"pattern-%u",pattern);compareScan(data,width,height,stride,label);
                }
                free(data);
            }
}
static void thresholdCases(void) {
    const uint8_t values[]={0,63,64,65,66,189,190,191,192,255};
    const size_t width=33,height=3;size_t stride=0;uint8_t *data=image(width,height,7,&stride);
    size_t position=0;
    for(size_t b=0;b<sizeof(values);b++)for(size_t g=0;g<sizeof(values);g++)
        for(size_t r=0;r<sizeof(values);r++)for(size_t a=0;a<sizeof(values);a++){
            for(size_t y=0;y<height;y++)memset(data+y*stride,0,width*4);
            size_t x=position++%width;uint8_t *pixel=data+stride+4*x;
            pixel[0]=values[b];pixel[1]=values[g];pixel[2]=values[r];pixel[3]=values[a];
            char label[80];snprintf(label,sizeof(label),"BGRA=%u/%u/%u/%u lane=%zu",pixel[0],pixel[1],pixel[2],pixel[3],x);
            compareScan(data,width,height,stride,label);
        }
    // Walk exactly one matching pixel through every vector/tail position, so
    // both64-bit mask halves and empty neighbouring chunks are exercised.
    for(size_t y=0;y<height;y++)for(size_t x=0;x<width;x++){
        for(size_t row=0;row<height;row++)memset(data+row*stride,0,width*4);
        uint8_t *pixel=data+y*stride+4*x;pixel[0]=255;pixel[1]=0;pixel[2]=255;pixel[3]=255;
        compareScan(data,width,height,stride,"single-hit-position");
    }
    free(data);
}
int main(void) { @autoreleasepool {
    char model[128]={0};size_t length=sizeof(model);
    if(sysctlbyname("hw.model",model,&length,NULL,0)||strncmp(model,"VirtualMac",10)){
        fputs("VM-only scan contract refused this host; do not execute tests on the laptop\n",stderr);return 3;
    }
    patternCases();thresholdCases();
    printf("PASS: %zu exact scalar/NEON scan equivalence cases; no capture/native-window operations or performance claim\n",scanCases);
    return 0;
} }
