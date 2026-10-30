// SPDX-License-Identifier: GPL-3.0-or-later
// The shell's owner-only state files, header-only so that each module that keeps one (DWDockReloader.m's pause,
// DWNativeDesktopCLI.m's login-mode record, DWSystemTakeover.m's preference snapshot) and each regression builds
// without the others' object files. A record is a property list that only its owner may write or trust: a regular
// file, owned by this user, mode 0600, found with lstat so that a symlink is never followed.
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

// ~/Library/Application Support/Infinify, where the scene, the socket, the preference snapshot and the native-desktop
// state directory live.
static inline NSString *DWSupportDirectory(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Infinify"];
}

// YES when path is a regular file of this user's with mode exactly 0600.
static inline BOOL DWOwnerFileIsPrivate(NSString *path) {
    struct stat st;
    return lstat(path.fileSystemRepresentation,&st)==0&&S_ISREG(st.st_mode)&&st.st_uid==getuid()&&(st.st_mode&07777)==0600;
}

// Writes data to path so that a crash at any point leaves the old file or the whole new one: a new 0600 file beside it
// (O_EXCL and O_NOFOLLOW, named for this process; a leftover of that name from a dead process is removed once), written,
// flushed to the disk (F_FULLFSYNC, else fsync), renamed over path, and the directory flushed. On any failure the new file
// is removed and path is untouched. The directory must exist.
static inline BOOL DWOwnerFileWrite(NSString *path,NSData *data) {
    if(!data)return NO;
    NSString *directory=path.stringByDeletingLastPathComponent,*aside=[path stringByAppendingFormat:@".%d.tmp",getpid()];
    int fd=open(aside.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0&&errno==EEXIST){unlink(aside.fileSystemRepresentation);fd=open(aside.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);}
    if(fd<0)return NO;
    const uint8_t *bytes=data.bytes;size_t left=data.length;BOOL ok=YES;
    while(left&&ok){ssize_t n=write(fd,bytes,left);if(n<0&&errno==EINTR)continue;if(n<=0)ok=NO;else{bytes+=n;left-=(size_t)n;}}
    if(ok&&fcntl(fd,F_FULLFSYNC)!=0)ok=fsync(fd)==0;
    ok=close(fd)==0&&ok;
    if(!ok||rename(aside.fileSystemRepresentation,path.fileSystemRepresentation)!=0){unlink(aside.fileSystemRepresentation);return NO;}
    int parent=open(directory.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_CLOEXEC);if(parent>=0){fsync(parent);close(parent);}
    return YES;
}

// DWOwnerFileWrite of an XML property list.
static inline BOOL DWOwnerFileWritePlist(NSString *path,NSDictionary *record) {
    return DWOwnerFileWrite(path,[NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL]);
}

// The dictionary a private file holds, or nil when there is no such file, it is not private, or it is not a dictionary.
static inline NSDictionary *DWOwnerFileReadPlist(NSString *path) {
    if(!DWOwnerFileIsPrivate(path))return nil;
    NSDictionary *record=[NSDictionary dictionaryWithContentsOfFile:path];
    return [record isKindOfClass:NSDictionary.class]?record:nil;
}

// Removes the file at path (a symlink itself, not what it points to). YES when there was one and it is gone.
static inline BOOL DWOwnerFileRemove(NSString *path) {
    struct stat st;
    return lstat(path.fileSystemRepresentation,&st)==0&&unlink(path.fileSystemRepresentation)==0;
}
