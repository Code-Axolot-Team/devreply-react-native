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

- (void)present:(NSString *)category
{
  [_bridge present:category];
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
