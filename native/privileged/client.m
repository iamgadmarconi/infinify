// SPDX-License-Identifier: GPL-3.0-or-later
// Small POSIX socket client; Foundation is used only for JSON encoding/decoding.
#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <unistd.h>
#import <poll.h>
#import "protocol.h"
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=3){fprintf(stderr,"usage: client private-runtime nonce < requests.jsonl\nEach input line is a JSON object; v and nonce are added. Connection stays open until stdin EOF.\n");return 2;}
    struct stat st;if(lstat(argv[1],&st)||!S_ISDIR(st.st_mode)||st.st_uid!=getuid()||(st.st_mode&0777)!=0700)return 2;
    struct sockaddr_un addr={.sun_family=AF_UNIX};
    if(snprintf(addr.sun_path,sizeof(addr.sun_path),"%s/helper.sock",argv[1])>=(int)sizeof(addr.sun_path))return 2;
    if(lstat(addr.sun_path,&st)||!S_ISSOCK(st.st_mode)||st.st_uid!=getuid()||(st.st_mode&0777)!=0600)return 2;
    int fd=socket(AF_UNIX,SOCK_STREAM,0);if(fd<0||connect(fd,(struct sockaddr *)&addr,sizeof(addr))){perror("connect");return 1;}
    uid_t uid;gid_t gid;if(getpeereid(fd,&uid,&gid)||uid!=getuid()){fprintf(stderr,"server UID mismatch\n");return 1;}
    int one=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
    struct timeval timeout={.tv_sec=3};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
    char line[DW_MAX_PACKET];int result=0;
    while(fgets(line,sizeof(line),stdin)) {
        if(!strchr(line,'\n')){fprintf(stderr,"input line too long or missing newline\n");result=2;break;}
        NSData *data=[[NSString stringWithUTF8String:line] dataUsingEncoding:NSUTF8StringEncoding];
        id parsed=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
        if(![parsed isKindOfClass:NSMutableDictionary.class]){result=2;break;}
        parsed[@"v"]=@1;parsed[@"nonce"]=[NSString stringWithUTF8String:argv[2]];
        NSData *encoded=[NSJSONSerialization dataWithJSONObject:parsed options:0 error:NULL];
        if(encoded.length>=DW_MAX_PACKET){result=2;break;}
        NSMutableData *packet=[encoded mutableCopy];[packet appendBytes:"\n" length:1];
        size_t sent=0;while(sent<packet.length){ssize_t n=write(fd,(char *)packet.bytes+sent,packet.length-sent);if(n<=0){result=1;break;}sent+=n;}if(result)break;
        size_t used=0;while(used<sizeof(line)-1){ssize_t n=read(fd,line+used,1);if(n<=0)break;if(line[used++]=='\n')break;}
        if(!used||line[used-1]!='\n'){fprintf(stderr,"response disconnected or too large\n");result=1;break;}
        fwrite(line,1,used,stdout);fflush(stdout);
        data=[NSData dataWithBytes:line length:used];NSDictionary *response=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if(![response[@"ok"] boolValue]){result=1;break;}
    }
    close(fd);return result;
} }
