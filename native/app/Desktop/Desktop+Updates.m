// SPDX-License-Identifier: GPL-3.0-or-later
// New implementation. Desktop updates: a desktop run reads whether a newer release is out (DWUpdateCheck.h) when it starts
// and every six hours after, and tells the owner once per version with a notification. Infinify has no window or menu of
// its own while it is the desktop, so the notification is where the news shows; its click opens the setup assistant at
// its Ready pane (`setup --update`), which says how to update, whatever pane setup would resume at. macOS asks once
// whether Infinify may notify, the first time there is news.
#import "Desktop+Private.h"
#import "DWOwnerFile.h"
#import "DWUpdateCheck.h"

static NSString *const kUpdateNotification=@"com.marengox.infinify.update";

@implementation Desktop (Updates)
- (void)watchForUpdates {
    if(self.windowed||!self.managing||self.scope)return;
    UNUserNotificationCenter.currentNotificationCenter.delegate=self;
    __weak Desktop *weak=self;
    void (^look)(void)=^{DWUpdateCheckIfDue(DWSupportDirectory(),^(NSDictionary<NSString *,NSString *> *newer){[weak tellAboutUpdate:newer];});};
    look();
    // The check itself reads GitHub at most once a day; looking more often only catches a day that ended while the Mac slept.
    [NSTimer scheduledTimerWithTimeInterval:6*60*60 repeats:YES block:^(NSTimer *timer){(void)timer;look();}];
}
- (void)tellAboutUpdate:(NSDictionary<NSString *,NSString *> *)newer {
    if(!newer||!DWUpdateFirstNoticeOf(DWSupportDirectory(),newer[@"version"]))return;
    UNUserNotificationCenter *center=UNUserNotificationCenter.currentNotificationCenter;
    [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert completionHandler:^(BOOL granted,NSError *error){
        (void)error;if(!granted)return;
        UNMutableNotificationContent *content=[UNMutableNotificationContent new];
        content.title=[NSString stringWithFormat:@"Infinify %@ is out",newer[@"version"]];
        content.body=@"Open Infinify to see how to update.";
        [center addNotificationRequest:[UNNotificationRequest requestWithIdentifier:kUpdateNotification content:content trigger:nil] withCompletionHandler:nil];
    }];
}
// Infinify counts as the app in front while it is the desktop: without this its own notification would not show.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    (void)center;(void)notification;completionHandler(UNNotificationPresentationOptionBanner|UNNotificationPresentationOptionList);
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void (^)(void))completionHandler {
    (void)center;
    if([response.notification.request.identifier isEqual:kUpdateNotification])dispatch_async(dispatch_get_main_queue(),^{[self openSetupAssistant:@[@"--update"]];});
    completionHandler();
}
@end
