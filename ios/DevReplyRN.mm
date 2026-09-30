#import "DevReplyRN.h"

#if __has_include(<DevReplyReactNative/DevReplyReactNative-Swift.h>)
#import <DevReplyReactNative/DevReplyReactNative-Swift.h>
#else
#import "DevReplyReactNative-Swift.h"
#endif

@implementation DevReplyRN {
  DevReplyBridge *_bridge;
}

- (instancetype)init
{
  if (self = [super init]) {
    _bridge = [DevReplyBridge new];
    __weak DevReplyRN *weakSelf = self;
    _bridge.onUnread = ^(NSInteger count) {
      [weakSelf emitOnUnreadChange:@{@"count" : @(count)}];
    };
    _bridge.onEvent = ^(NSString *type, NSString *conversationId, NSString *category) {
      [weakSelf emitOnEvent:@{
        @"type" : type,
        @"conversationId" : conversationId ?: (id)[NSNull null],
        @"category" : category ?: (id)[NSNull null],
      }];
    };
  }
  return self;
}

+ (NSString *)moduleName
{
  return @"DevReply";
}

- (void)configure:(NSString *)publicKey
{
  [_bridge configure:publicKey];
}

- (void)login:(NSString *)userId
{
  [_bridge login:userId];
}

- (void)logout
{
  [_bridge logout];
}

- (void)deleteUser:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  [_bridge deleteUser:^(BOOL ok) {
    resolve(@(ok));
  }];
}

- (NSNumber *)present:(NSString *)category message:(NSString *)message attributes:(NSDictionary *)attributes askName:(BOOL)askName
{
  return @([_bridge present:category message:message attributes:attributes ?: @{} askName:askName]);
}

- (NSNumber *)isAvailable
{
  return @(_bridge.isAvailable);
}

- (void)setTheme:(NSString *)lightMode light:(NSDictionary *)light darkMode:(NSString *)darkMode dark:(NSDictionary *)dark
{
  [_bridge setTheme:lightMode light:light darkMode:darkMode dark:dark];
}

- (void)setUser:(NSString *)name email:(NSString *)email
{
  [_bridge setUser:name email:email];
}

- (void)setAttributes:(NSDictionary *)attributes
{
  [_bridge setAttributes:attributes];
}

- (NSNumber *)getUnreadCount
{
  return @(_bridge.unreadCount);
}

- (void)setShowsUnreadBubble:(BOOL)shows
{
  [_bridge setShowsUnreadBubble:shows];
}

- (void)registerPushToken:(NSString *)hexToken
{
  [_bridge registerPushToken:hexToken];
}

- (NSNumber *)handleNotificationOpened:(NSDictionary *)data
{
  return @([_bridge handleNotificationOpened:data]);
}

- (NSNumber *)handlePush:(NSDictionary *)data
{
  // iOS shows DevReply's pushes itself (APNs).
  return @NO;
}

- (void)handle:(NSString *)url
{
  [_bridge handle:url];
}

- (void)setLocale:(NSString *)tag
{
  [_bridge setLocale:tag];
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeDevReplySpecJSI>(params);
}

@end
