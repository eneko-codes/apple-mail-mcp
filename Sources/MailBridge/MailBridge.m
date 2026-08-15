#import "MailBridge.h"

#import <AppKit/AppKit.h>
#import <ScriptingBridge/ScriptingBridge.h>

// Hand-declared bindings for Mail, covering only the members this server sends.
//
// `sdef /System/Applications/Mail.app | sdp -fh` generates a 637-line header; declaring
// the handful of members actually used is smaller and auditable. Every selector here was
// checked against Mail's scripting dictionary — confirm before adding one:
//
//     sdef /System/Applications/Mail.app | grep 'name="date received"'
//
// Scripting Bridge camel-cases dictionary names: `date received` becomes `dateReceived`,
// and the `to recipient` element becomes `toRecipients`.
//
// One member is deliberately absent. Mail's `account` class exposes `password`, in plain
// text. It is not declared anywhere here, which makes it unreachable from this process —
// the narrow protocol is the safeguard. For the same reason nothing is declared "in case
// it is useful later": every member is one this server sends.

@protocol MailRecipient <NSObject>
@property (copy) NSString *address;
@property (copy) NSString *name;
@end

@protocol MailMessage <NSObject>
@property (readonly) NSInteger id;
@property (copy, readonly) NSString *subject;
@property (copy, readonly) NSString *sender;
@property (copy, readonly) NSDate *dateReceived;
@property (copy, readonly) NSDate *dateSent;
@property (readonly) BOOL readStatus;
@property (copy, readonly) NSString *messageId;
@property (copy, readonly) NSString *replyTo;
@property (readonly) SBElementArray<id<MailRecipient>> *toRecipients;
@property (readonly) SBElementArray<id<MailRecipient>> *ccRecipients;
/// `rich text` in the dictionary, so it may arrive as an NSString or as an SBObject
/// wrapping one depending on how the value is coerced. Typed `id` and resolved below.
@property (copy, readonly) id content;
@end

@protocol MailMailbox <NSObject>
@property (copy) NSString *name;
@property (readonly) NSInteger unreadCount;
@property (readonly) SBElementArray<id<MailMessage>> *messages;
@end

@protocol MailAccount <NSObject>
@property (copy) NSString *name;
@property (copy) NSArray<NSString *> *emailAddresses;
@property (readonly) SBElementArray<id<MailMailbox>> *mailboxes;
@end

@protocol MailOutgoingMessage <NSObject>
@property (copy) NSString *subject;
@property (copy) id content;
@property (copy) NSString *sender;
@property BOOL visible;
@property (readonly) SBElementArray<id<MailRecipient>> *toRecipients;
@property (readonly) SBElementArray<id<MailRecipient>> *ccRecipients;
@property (readonly) SBElementArray<id<MailRecipient>> *bccRecipients;
- (BOOL)send;
@end

@protocol MailApplication <NSObject>
@property (readonly) SBElementArray<id<MailAccount>> *accounts;
@property (readonly) SBElementArray<id<MailOutgoingMessage>> *outgoingMessages;
@end

NSString *const MailBridgeErrorDomain = @"codes.eneko.apple-mail-mcp";
static NSString *const MailBundleIdentifier = @"com.apple.mail";

@implementation MailBridge

#pragma mark - Plumbing

+ (BOOL)isMailRunning {
    return [NSRunningApplication
               runningApplicationsWithBundleIdentifier:MailBundleIdentifier].count > 0;
}

+ (NSError *)errorWithCode:(MailBridgeError)code message:(NSString *)message {
    return [NSError errorWithDomain:MailBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// The application object, or nil with `error` set. Casting to the protocol is a
/// compile-time annotation in Objective-C: no runtime check, no metadata symbol, and so
/// none of the trouble the same line causes in Swift.
+ (nullable SBApplication<MailApplication> *)applicationWithError:(NSError **)error {
    if (!self.isMailRunning) {
        if (error) *error = [self errorWithCode:MailBridgeErrorMailNotRunning message:@"Mail is not running."];
        return nil;
    }
    SBApplication *application =
        [SBApplication applicationWithBundleIdentifier:MailBundleIdentifier];
    if (!application) {
        if (error) *error = [self errorWithCode:MailBridgeErrorNotReachable message:@"Mail could not be reached."];
        return nil;
    }
    // No launch flag is set to keep Mail from starting, because none exists: the guard is
    // the isMailRunning check above. Launching an app on the owner's behalf is a side
    // effect they did not ask for, and Scripting Bridge offers no way to forbid it.
    return (SBApplication<MailApplication> *)application;
}

/// Resolves a `rich text` property to a plain string, whichever shape it arrives in.
+ (NSString *)plainTextFrom:(id)value {
    if (!value) return @"";
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSAttributedString.class]) return [value string];
    if ([value isKindOfClass:SBObject.class]) return [self plainTextFrom:[value get]];
    return @"";
}

+ (nullable id<MailAccount>)accountNamed:(NSString *)name
                            inApplication:(SBApplication<MailApplication> *)application {
    for (id<MailAccount> account in application.accounts) {
        if ([account.name isEqualToString:name]) return account;
    }
    return nil;
}

+ (nullable id<MailMailbox>)mailboxNamed:(NSString *)name inAccount:(id<MailAccount>)account {
    for (id<MailMailbox> mailbox in account.mailboxes) {
        if ([mailbox.name caseInsensitiveCompare:name] == NSOrderedSame) return mailbox;
    }
    return nil;
}

+ (nullable id<MailMailbox>)mailbox:(NSString *)mailbox
                          inAccount:(NSString *)accountName
                      ofApplication:(SBApplication<MailApplication> *)application
                              error:(NSError **)error {
    id<MailAccount> account = [self accountNamed:accountName inApplication:application];
    if (!account) {
        if (error) {
            *error = [self errorWithCode:MailBridgeErrorAccountNotFound
                                 message:[NSString stringWithFormat:@"No account named '%@'.",
                                                                    accountName]];
        }
        return nil;
    }
    id<MailMailbox> box = [self mailboxNamed:mailbox inAccount:account];
    if (!box && error) {
        *error = [self errorWithCode:MailBridgeErrorMailboxNotFound
                             message:[NSString stringWithFormat:@"No mailbox '%@' in account '%@'.",
                                                                mailbox, accountName]];
    }
    return box;
}

#pragma mark - Reads

+ (nullable NSArray<NSDictionary<NSString *, id> *> *)accountsWithError:(NSError **)error {
    SBApplication<MailApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    NSMutableArray<NSDictionary<NSString *, id> *> *results = [NSMutableArray array];
    for (id<MailAccount> account in application.accounts) {
        NSString *name = account.name;
        if (name.length == 0) continue;

        NSMutableArray<NSDictionary<NSString *, id> *> *mailboxes = [NSMutableArray array];
        for (id<MailMailbox> mailbox in account.mailboxes) {
            NSString *mailboxName = mailbox.name;
            if (mailboxName.length == 0) continue;
            [mailboxes addObject:@{@"name": mailboxName,
                                   @"unreadCount": @(mailbox.unreadCount)}];
        }
        [results addObject:@{@"name": name,
                             @"addresses": account.emailAddresses ?: @[],
                             @"mailboxes": mailboxes}];
    }
    return results;
}

+ (nullable NSDictionary<NSString *, id> *)scanMailbox:(NSString *)mailbox
                                             inAccount:(NSString *)accountName
                                              fromDate:(nullable NSDate *)fromDate
                                                toDate:(nullable NSDate *)toDate
                                               maxScan:(NSInteger)maxScan
                                                 error:(NSError **)error {
    SBApplication<MailApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    id<MailMailbox> box = [self mailbox:mailbox
                              inAccount:accountName
                          ofApplication:application
                                  error:error];
    if (!box) return nil;

    // The date bound is pushed into Mail as a `whose` clause. The unfiltered array is
    // only materialised when there is no bound to push down — building it first and then
    // discarding it would pay for the whole mailbox on exactly the path the bound exists
    // to avoid.
    NSArray *candidates;
    if (fromDate || toDate) {
        NSMutableArray<NSString *> *clauses = [NSMutableArray array];
        NSMutableArray *values = [NSMutableArray array];
        if (fromDate) { [clauses addObject:@"dateReceived >= %@"]; [values addObject:fromDate]; }
        if (toDate) { [clauses addObject:@"dateReceived <= %@"]; [values addObject:toDate]; }
        NSPredicate *predicate =
            [NSPredicate predicateWithFormat:[clauses componentsJoinedByString:@" AND "]
                               argumentArray:values];
        candidates = [box.messages filteredArrayUsingPredicate:predicate];
    } else {
        candidates = [box.messages get] ?: @[];
    }

    NSInteger scanned = 0;
    NSMutableArray<NSDictionary<NSString *, id> *> *messages = [NSMutableArray array];
    for (id<MailMessage> message in candidates) {
        if (scanned >= maxScan) break;
        scanned += 1;

        NSDate *received = message.dateReceived;
        [messages addObject:@{
            @"id": @(message.id),
            @"subject": message.subject ?: @"",
            @"sender": message.sender ?: @"",
            @"dateReceived": received ?: NSDate.distantPast,
            @"isRead": @(message.readStatus),
        }];
    }
    return @{@"scanned": @(scanned), @"messages": messages};
}

+ (NSArray<NSString *> *)addressesFrom:(SBElementArray<id<MailRecipient>> *)recipients {
    NSMutableArray<NSString *> *results = [NSMutableArray array];
    for (id<MailRecipient> recipient in recipients) {
        NSString *address = recipient.address;
        if (address.length == 0) continue;
        NSString *name = recipient.name;
        [results addObject:name.length > 0
                              ? [NSString stringWithFormat:@"%@ <%@>", name, address]
                              : address];
    }
    return results;
}

+ (nullable NSDictionary<NSString *, id> *)messageWithIdentifier:(NSInteger)identifier
                                                       inMailbox:(NSString *)mailbox
                                                         account:(NSString *)accountName
                                                           error:(NSError **)error {
    SBApplication<MailApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    id<MailMailbox> box = [self mailbox:mailbox
                              inAccount:accountName
                          ofApplication:application
                                  error:error];
    if (!box) return nil;

    // Matched inside Mail rather than by walking the mailbox here.
    NSArray *matching = [box.messages
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"id == %ld",
                                                                     (long)identifier]];
    id<MailMessage> message = matching.firstObject;
    if (!message) {
        if (error) {
            *error = [self errorWithCode:MailBridgeErrorMessageNotFound
                                 message:@"That mailbox no longer holds a message with "
                                          "that id."];
        }
        return nil;
    }

    NSString *replyTo = message.replyTo;
    NSString *rfcIdentifier = message.messageId;
    return @{
        @"id": @(message.id),
        @"subject": message.subject ?: @"",
        @"sender": message.sender ?: @"",
        @"recipients": [self addressesFrom:message.toRecipients],
        @"ccRecipients": [self addressesFrom:message.ccRecipients],
        @"replyTo": replyTo.length > 0 ? replyTo : NSNull.null,
        @"dateSent": message.dateSent ?: NSDate.distantPast,
        @"dateReceived": message.dateReceived ?: NSDate.distantPast,
        @"isRead": @(message.readStatus),
        @"mailbox": box.name ?: mailbox,
        @"rfcMessageID": rfcIdentifier.length > 0 ? rfcIdentifier : NSNull.null,
        @"body": [self plainTextFrom:message.content],
    };
}

#pragma mark - Send

+ (void)addRecipients:(NSArray<NSString *> *)addresses
                   to:(SBElementArray<id<MailRecipient>> *)element
             ofClass:(NSString *)scriptingClass
        inApplication:(SBApplication<MailApplication> *)application {
    for (NSString *address in addresses) {
        id recipient = [[[application classForScriptingClass:scriptingClass] alloc]
            initWithProperties:@{@"address": address}];
        if (recipient) [element addObject:recipient];
    }
}

+ (nullable NSString *)sendMessageFrom:(nullable NSString *)sender
                               subject:(NSString *)subject
                                  body:(NSString *)body
                          toRecipients:(NSArray<NSString *> *)toRecipients
                          ccRecipients:(NSArray<NSString *> *)ccRecipients
                         bccRecipients:(NSArray<NSString *> *)bccRecipients
                                 error:(NSError **)error {
    SBApplication<MailApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    Class outgoingClass = [application classForScriptingClass:@"outgoing message"];
    if (!outgoingClass) {
        if (error) {
            *error = [self errorWithCode:MailBridgeErrorComposeRefused
                                 message:@"Mail did not offer its outgoing message class."];
        }
        return nil;
    }

    // Properties are a dictionary of typed values, never text spliced into a script.
    id<MailOutgoingMessage> message = [[outgoingClass alloc] initWithProperties:@{
        @"subject": subject,
        @"content": body,
        @"visible": @NO,
    }];
    if (!message) {
        if (error) *error = [self errorWithCode:MailBridgeErrorComposeRefused
                                 message:@"Mail would not create the message."];
        return nil;
    }

    // Insert before touching anything else. Scripting Bridge: an object "is not viable in
    // the application until it has been added to its container. Consequently, you cannot
    // set or access its properties until it's been added."
    [application.outgoingMessages addObject:message];

    if (sender.length > 0) message.sender = sender;
    [self addRecipients:toRecipients
                     to:message.toRecipients
                ofClass:@"to recipient"
          inApplication:application];
    [self addRecipients:ccRecipients
                     to:message.ccRecipients
                ofClass:@"cc recipient"
          inApplication:application];
    [self addRecipients:bccRecipients
                     to:message.bccRecipients
                ofClass:@"bcc recipient"
          inApplication:application];

    // Read back before sending: a sent message is no longer there to be asked, and the
    // receipt should name the account the message actually left from rather than the one
    // the caller hoped for.
    NSString *resolvedSender = message.sender ?: @"";

    if (![message send]) {
        if (error) {
            *error = [self errorWithCode:MailBridgeErrorSendRefused
                                 message:@"Mail would not send the message; it may be "
                                          "left in Drafts."];
        }
        return nil;
    }
    return resolvedSender;
}

@end
