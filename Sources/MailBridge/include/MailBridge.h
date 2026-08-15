#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const MailBridgeErrorDomain;

/// Typed because Swift imports an `NSError **` method as `throws`, which would otherwise
/// flatten "this mailbox no longer holds that id" — an ordinary outcome, since ids go
/// stale whenever a message is moved — into the same channel as a real failure.
typedef NS_ERROR_ENUM(MailBridgeErrorDomain, MailBridgeError){
    MailBridgeErrorMailNotRunning = 1,
    MailBridgeErrorNotReachable,
    MailBridgeErrorAccountNotFound,
    MailBridgeErrorMailboxNotFound,
    MailBridgeErrorMessageNotFound,
    MailBridgeErrorComposeRefused,
    MailBridgeErrorSendRefused,
};

/// Everything this project sends to Mail, in Objective-C.
///
/// Objective-C rather than Swift on purpose, and not for taste. Apple documents exactly
/// one way to create a scriptable object — ask the application for the class with
/// `classForScriptingClass:`, `alloc`/`initWithProperties:` it, then insert it in the
/// container's element array — and that pattern cannot be expressed from Swift. The class
/// that comes back is an `SBPseudoClass`, which does not inherit from `SBObject` and turns
/// every class-level message into an `__NSMessageBuilder`, so a Swift metatype cast
/// against it aborts the process. Underneath is a Swift limitation of long standing: the
/// metadata symbols for Scripting Bridge classes do not exist at link time because the
/// classes are made at runtime (swiftlang/swift#43407, open since 2016).
///
/// In Objective-C none of that arises. A cast to a protocol is a compile-time annotation,
/// the documented creation pattern compiles as written, and no `unsafeBitCast` is needed
/// anywhere. The alternative — driving Mail through `NSAppleScript` — is the one thing
/// Apple's own guide tells you not to do: "You should not use NSAppleScript to execute a
/// script merely to result in sending an Apple event."
///
/// Everything crosses back to Swift as Foundation types, so no Scripting Bridge object
/// ever escapes this file. Policy — which mailboxes to walk, how to match a query, where
/// to stop, how to format — stays in Swift, where the tests can reach it.
///
/// Caller strings are passed as typed parameters throughout. There is no script source to
/// splice them into, which is the injection guarantee this project has always had.
@interface MailBridge : NSObject

/// Whether Mail is running. This server never launches it.
@property (class, readonly) BOOL isMailRunning;

/// Every account, as `{name, addresses, mailboxes: [{name, unreadCount}]}`.
+ (nullable NSArray<NSDictionary<NSString *, id> *> *)accountsWithError:(NSError **)error;

/// Walks one mailbox and returns `{scanned, messages: [{id, subject, sender,
/// dateReceived, isRead}]}`.
///
/// A date bound is pushed into Mail as a `whose` clause rather than applied here:
/// filtering in Mail is dramatically faster than shipping every message across the Apple
/// event boundary. `maxScan` bounds the walk; `scanned` reports how far it actually got,
/// which is what lets the caller say a result was truncated.
+ (nullable NSDictionary<NSString *, id> *)scanMailbox:(NSString *)mailbox
                                             inAccount:(NSString *)account
                                              fromDate:(nullable NSDate *)fromDate
                                                toDate:(nullable NSDate *)toDate
                                               maxScan:(NSInteger)maxScan
                                                 error:(NSError **)error;

/// One message with its body, or nil if the mailbox no longer holds that id.
+ (nullable NSDictionary<NSString *, id> *)messageWithIdentifier:(NSInteger)identifier
                                                       inMailbox:(NSString *)mailbox
                                                         account:(NSString *)account
                                                           error:(NSError **)error;

/// Composes and sends, returning the address Mail resolved as the sender.
///
/// Order matters and is Apple's, not a preference: the message is created, **then** added
/// to `outgoingMessages`, and only then are its sender and recipients set. Scripting
/// Bridge documents that an object "is not viable in the application until it has been
/// added to its container. Consequently, you cannot set or access its properties until
/// it's been added."
///
/// Irreversible. There is no recall.
+ (nullable NSString *)sendMessageFrom:(nullable NSString *)sender
                               subject:(NSString *)subject
                                  body:(NSString *)body
                          toRecipients:(NSArray<NSString *> *)toRecipients
                          ccRecipients:(NSArray<NSString *> *)ccRecipients
                         bccRecipients:(NSArray<NSString *> *)bccRecipients
                                 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
