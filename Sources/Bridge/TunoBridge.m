//  TunoBridge.m
//  Tuno
//
//  Created by Kaan Firat.
//
//  Reads the system Now Playing session through the private MediaRemote
//  framework. Since macOS 15.4 MediaRemote only answers entitled Apple
//  processes, so this is built as a dylib and loaded into /usr/bin/perl
//  (see Resources/tuno-bridge.pl), which runs with the platform context
//  MediaRemote accepts.
//
//  Entry points (called by name from the perl loader):
//    tuno_snapshot   print one JSON line and return
//    tuno_stream     print a JSON line on every change until stdin closes;
//                    any line received on stdin forces a full snapshot
//
//  Line format, every key optional; `{}` or no title means nothing playing:
//    title, artist, album, bundleIdentifier : string
//    playing, hasArtwork                    : bool
//    duration, elapsedTime                  : seconds
//    timestamp                              : Unix time elapsedTime was sampled at
//    playbackRate                           : number
//    artwork, artworkType                   : base64 image and its MIME type.
//        tuno_stream sends these only when the image changes (or on a forced
//        snapshot); readers keep the previous image while hasArtwork is true.

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define TUNO_EXPORT __attribute__((visibility("default")))

#pragma mark - MediaRemote symbols

typedef void (*MRRegisterForNotifications)(dispatch_queue_t);
typedef void (*MRGetNowPlayingInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetIsPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetClient)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*MRClientString)(id);

static struct {
    MRRegisterForNotifications registerForNotifications;
    MRGetNowPlayingInfo getInfo;
    MRGetIsPlaying getIsPlaying;
    MRGetClient getClient;
    MRClientString clientBundleID;
    MRClientString clientParentBundleID;
} MR;

/// MediaRemote replies arrive here. Nothing may block on this queue while
/// waiting for a reply, or the reply can never be delivered.
static dispatch_queue_t replyQueue;

static BOOL TBLoad(void) {
    static BOOL ok;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [NSURL fileURLWithPath:@"/System/Library/PrivateFrameworks/MediaRemote.framework"];
        CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)url);
        if (!bundle) return;
#define TB_SYMBOL(name) CFBundleGetFunctionPointerForName(bundle, CFSTR(name))
        MR.registerForNotifications = TB_SYMBOL("MRMediaRemoteRegisterForNowPlayingNotifications");
        MR.getInfo                  = TB_SYMBOL("MRMediaRemoteGetNowPlayingInfo");
        MR.getIsPlaying             = TB_SYMBOL("MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        MR.getClient                = TB_SYMBOL("MRMediaRemoteGetNowPlayingClient");
        MR.clientBundleID           = TB_SYMBOL("MRNowPlayingClientGetBundleIdentifier");
        MR.clientParentBundleID     = TB_SYMBOL("MRNowPlayingClientGetParentAppBundleIdentifier");
#undef TB_SYMBOL
        replyQueue = dispatch_queue_create("com.kaanfirat.tuno.bridge.reply", DISPATCH_QUEUE_SERIAL);
        if (MR.registerForNotifications) MR.registerForNotifications(replyQueue);
        ok = MR.getInfo != NULL;
    });
    return ok;
}

#pragma mark - Snapshot

@interface TBSnapshot : NSObject
@property (nonatomic, strong) NSMutableDictionary *fields;   // everything but the artwork
@property (nonatomic, strong) NSData *artwork;
@property (nonatomic, copy) NSString *artworkType;
@end

@implementation TBSnapshot
@end

static id TBTyped(NSDictionary *info, NSString *key, Class cls) {
    id value = info[key];
    return [value isKindOfClass:cls] ? value : nil;
}

static NSString *TBClientBundleID(id client) {
    if (!client || !MR.clientBundleID) return nil;
    // Web players run in helper processes; the parent is the browser itself.
    CFStringRef parent = MR.clientParentBundleID ? MR.clientParentBundleID(client) : NULL;
    if (parent && CFStringGetLength(parent) > 0) return [(__bridge NSString *)parent copy];
    CFStringRef own = MR.clientBundleID(client);
    return own ? [(__bridge NSString *)own copy] : nil;
}

/// Ask MediaRemote for the current session. Blocks for at most two seconds.
static TBSnapshot *TBTakeSnapshot(void) {
    TBSnapshot *snap = [TBSnapshot new];
    snap.fields = [NSMutableDictionary dictionary];
    if (!TBLoad()) return snap;

    __block NSDictionary *info = nil;
    __block BOOL playing = NO;
    __block NSString *clientID = nil;
    dispatch_group_t pending = dispatch_group_create();

    dispatch_group_enter(pending);
    MR.getInfo(replyQueue, ^(NSDictionary *reply) {
        info = reply;
        dispatch_group_leave(pending);
    });
    if (MR.getIsPlaying) {
        dispatch_group_enter(pending);
        MR.getIsPlaying(replyQueue, ^(Boolean reply) {
            playing = reply;
            dispatch_group_leave(pending);
        });
    }
    // Recent macOS no longer puts the client's bundle id in the info
    // dictionary, so ask for the client separately.
    if (MR.getClient) {
        dispatch_group_enter(pending);
        MR.getClient(replyQueue, ^(id client) {
            clientID = TBClientBundleID(client);
            dispatch_group_leave(pending);
        });
    }
    dispatch_group_wait(pending, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));

    NSMutableDictionary *f = snap.fields;
    NSString *(^str)(NSString *) = ^(NSString *key) { return (NSString *)TBTyped(info, key, [NSString class]); };
    NSNumber *(^num)(NSString *) = ^(NSString *key) { return (NSNumber *)TBTyped(info, key, [NSNumber class]); };

    f[@"title"]            = str(@"kMRMediaRemoteNowPlayingInfoTitle");
    f[@"artist"]           = str(@"kMRMediaRemoteNowPlayingInfoArtist");
    f[@"album"]            = str(@"kMRMediaRemoteNowPlayingInfoAlbum");
    f[@"bundleIdentifier"] = str(@"kMRMediaRemoteNowPlayingInfoClientBundleIdentifier") ?: clientID;
    f[@"duration"]         = num(@"kMRMediaRemoteNowPlayingInfoDuration");
    f[@"elapsedTime"]      = num(@"kMRMediaRemoteNowPlayingInfoElapsedTime");
    f[@"playbackRate"]     = num(@"kMRMediaRemoteNowPlayingInfoPlaybackRate");
    NSDate *sampledAt = TBTyped(info, @"kMRMediaRemoteNowPlayingInfoTimestamp", [NSDate class]);
    if (sampledAt) f[@"timestamp"] = @(sampledAt.timeIntervalSince1970);
    f[@"playing"] = @(playing);

    NSData *artwork = TBTyped(info, @"kMRMediaRemoteNowPlayingInfoArtworkData", [NSData class]);
    if (artwork.length > 0) {
        snap.artwork = artwork;
        snap.artworkType = str(@"kMRMediaRemoteNowPlayingInfoArtworkMIMEType");
    }
    f[@"hasArtwork"] = @((BOOL)(snap.artwork != nil));
    return snap;
}

static void TBPrint(NSDictionary *line) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:line options:0 error:NULL] ?: [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static NSDictionary *TBLine(TBSnapshot *snap, BOOL withArtwork) {
    NSMutableDictionary *line = [snap.fields mutableCopy];
    if (withArtwork && snap.artwork) {
        line[@"artwork"] = [snap.artwork base64EncodedStringWithOptions:0];
        if (snap.artworkType) line[@"artworkType"] = snap.artworkType;
    }
    return line;
}

TUNO_EXPORT void tuno_snapshot(void) {
    @autoreleasepool {
        TBPrint(TBLine(TBTakeSnapshot(), YES));
    }
}

#pragma mark - Stream

// Stream state; only touched on streamQueue.
static dispatch_queue_t streamQueue;
static NSDictionary *sentFields;
static NSData *sentArtwork;
static uint64_t wakeToken;
static BOOL wakeForced;

static void TBSendIfChanged(BOOL forced) {
    @autoreleasepool {
        TBSnapshot *snap = TBTakeSnapshot();
        BOOL newArtwork = snap.artwork != sentArtwork && ![snap.artwork isEqualToData:sentArtwork];
        if (!forced && !newArtwork && [snap.fields isEqualToDictionary:sentFields]) return;

        sentFields = [snap.fields copy];
        sentArtwork = snap.artwork;
        // A forced snapshot usually means the reader just (re)started and has
        // no image yet, so include it even if it hasn't changed.
        TBPrint(TBLine(snap, newArtwork || forced));
    }
}

/// A track change posts several notifications at once; wait until they go
/// quiet briefly and take a single snapshot.
static void TBWake(BOOL forced) {
    dispatch_async(streamQueue, ^{
        uint64_t token = ++wakeToken;
        wakeForced |= forced;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), streamQueue, ^{
            if (token != wakeToken) return;
            BOOL f = wakeForced;
            wakeForced = NO;
            TBSendIfChanged(f);
        });
    });
}

TUNO_EXPORT void tuno_stream(void) {
    @autoreleasepool {
        streamQueue = dispatch_queue_create("com.kaanfirat.tuno.bridge.stream", DISPATCH_QUEUE_SERIAL);
        if (!TBLoad()) {
            TBPrint(@{});
            return;
        }

        for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange"]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                                                        usingBlock:^(NSNotification *note) { TBWake(NO); }];
        }

        // Browsers don't reliably notify on pause or seek. Re-checking in
        // process is cheap and prints nothing unless something changed.
        dispatch_source_t recheck = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, streamQueue);
        dispatch_source_set_timer(recheck, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                                  3 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(recheck, ^{ TBSendIfChanged(NO); });
        dispatch_resume(recheck);

        // stdin carries refresh requests; EOF means Tuno is gone, so exit
        // rather than linger as an orphan.
        dispatch_source_t requests = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0,
                                                            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_event_handler(requests, ^{
            char scratch[256];
            if (read(STDIN_FILENO, scratch, sizeof scratch) <= 0) exit(0);
            TBWake(YES);
        });
        dispatch_resume(requests);

        TBWake(YES);

        // A run loop with no sources returns immediately; the idle timer keeps
        // it running for anything MediaRemote schedules on the main thread.
        [NSTimer scheduledTimerWithTimeInterval:3600 repeats:YES block:^(NSTimer *timer) {}];
        [NSRunLoop.mainRunLoop run];
    }
}
