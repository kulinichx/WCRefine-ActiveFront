// Execute the production runtime glue with small host stand-ins. This does not
// load WeChat; it covers callback ordering, native row identity and UIKit life.
#define WCRAF_ACTIVITY_TESTS 1
#include "../ActiveFront.m"

static NSUInteger activityChecks;
static NSString *testAccount;
static NSString *testChatName;
static NSMutableDictionary *testSessions;
static BOOL testBypassAlias;
static BOOL testDeferUnread;
static BOOL testSwitchInsideUnread;
static NSUInteger testLookups;

static void ActivityCheck(BOOL condition, NSString *message) {
    activityChecks++;
    if (!condition) @throw [NSException exceptionWithName:@"ActivityIntegrationFailure"
        reason:message userInfo:nil];
}

@interface ActivitySession : NSObject
@property(nonatomic, copy) NSString *m_nsUsrName;
@property(nonatomic, strong) NSNumber *m_uUnReadCount;
@property(nonatomic) NSTimeInterval m_uLastTime;
@property(nonatomic) BOOL m_bShowUnReadAsRedDot;
@property(nonatomic) BOOL m_isFolding;
@end
@implementation ActivitySession
@end

@interface NewMainFrameCell : UITableViewCell
@property(nonatomic, strong) id cellData;
@end
@implementation NewMainFrameCell
@end
@interface MainFrameTableView : UITableView
@end
@implementation MainFrameTableView
@end

@interface BaseMsgContentViewController : UIViewController
@property(nonatomic, strong) ActivitySession *contact;
- (id)GetContact;
@end
@implementation BaseMsgContentViewController
- (id)GetContact { return self.contact; }
@end

@implementation WCRefineHelper
+ (NSString *)wcr_resolveCurrentUserWxidUncached { return testAccount; }
+ (id)currentChatContactFromTopViewController { return testSessions[testChatName]; }
@end
@implementation WCRefineConfig
+ (instancetype)shared {
    static WCRefineConfig *value;
    if (!value) value = [self new];
    return value;
}
@end
@implementation WCRefineGroup
@end
@implementation WCRefineGroupManager
+ (instancetype)shared {
    static WCRefineGroupManager *value;
    if (!value) value = [self new];
    return value;
}
- (NSArray *)customGroups {
    WCRefineGroup *group = [WCRefineGroup new];
    group.groupId = @"runtime-test-group";
    group.members = [NSSet setWithArray:testSessions.allKeys];
    return @[group];
}
- (NSArray *)groupIdsContainingMember:(NSString *)name {
    return testSessions[name] ? @[@"runtime-test-group"] : @[];
}
- (BOOL)addMember:(NSString *)name toGroup:(NSString *)group { (void)name; (void)group; return NO; }
- (BOOL)removeMember:(NSString *)name fromGroup:(NSString *)group { (void)name; (void)group; return NO; }
@end
@implementation WCRefineGroupDataProvider
+ (instancetype)shared {
    static WCRefineGroupDataProvider *value;
    if (!value) value = [self new];
    return value;
}
- (id)nativeSessionFromObject:(id)object { return object; }
- (NSString *)usernameForNativeObject:(id)object { return WCRMessageValue(object, @"m_nsUsrName"); }
- (NSUInteger)groupScopeForNativeSession:(id)session { (void)session; return 2; }
- (BOOL)shouldExcludeNativeSessionFromGroupingForUnreadPolicy:(id)session { (void)session; return NO; }
- (id)fulfilledSessionForUsername:(NSString *)name fallback:(id)fallback {
    testLookups++;
    return testSessions[name] ?: fallback;
}
- (id)nativeCellDataForSession:(id)session { return session; }
@end

@interface NewMainFrameViewController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UITableView *testTable;
@property(nonatomic, strong) ActivitySession *testSession;
@property(nonatomic, strong) BaseMsgContentViewController *testChat;
@property(nonatomic) NSUInteger refreshes;
@property(nonatomic) NSUInteger aliasCalls;
- (void)wcrGrouping_tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path;
@end
@implementation NewMainFrameViewController
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.testTable = [[MainFrameTableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.testTable.dataSource = self;
    self.testTable.delegate = self;
    [self.view addSubview:self.testTable];
}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    (void)table; (void)section; return self.testSession ? 1 : 0;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)table; (void)path;
    NewMainFrameCell *cell = [[NewMainFrameCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.cellData = self.testSession;
    return cell;
}
- (id)logicGetSessionAtIndexPath:(NSIndexPath *)path { (void)path; return self.testSession; }
- (id)wcrGrouping_logicGetSessionAtIndexPath:(NSIndexPath *)path { (void)path; return self.testSession; }
- (id)wcrGrouping_logicGetCellDataAtIndexPath:(NSIndexPath *)path { (void)path; return self.testSession; }
- (void)wcrGrouping_tableView:(UITableView *)table willDisplayCell:(UITableViewCell *)cell
           forRowAtIndexPath:(NSIndexPath *)path { (void)table; (void)cell; (void)path; }
- (void)wcrGrouping_scheduleRefreshForTrigger:(id)trigger {
    ActivityCheck([trigger isEqual:@"reloadAll"] || [trigger isEqual:@"groupsChanged"], @"Host rebuild trigger");
    self.refreshes++;
}
- (void)openTestChat {
    testChatName = self.testSession.m_nsUsrName;
    BaseMsgContentViewController *chat = [BaseMsgContentViewController new];
    chat.contact = self.testSession;
    self.testChat = chat;
    [self addChildViewController:chat];
    chat.view.frame = CGRectMake(0, 200, 100, 100);
    [self.view addSubview:chat.view];
    [chat didMoveToParentViewController:self];
    [chat viewDidAppear:NO];
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    (void)path;
    if (testBypassAlias) [self openTestChat];
    else [self wcrGrouping_tableView:table didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:99 inSection:0]];
}
- (void)wcrGrouping_tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    ActivityCheck([table cellForRowAtIndexPath:path] == nil, @"Native index differs from displayed row");
    self.aliasCalls++;
    [self openTestChat];
}
@end

@interface MMNewSessionMgr : NSObject
- (void)ChangeSessionUnReadCount:(NSString *)name to:(unsigned int)count;
@end
@implementation MMNewSessionMgr
- (void)ChangeSessionUnReadCount:(NSString *)name to:(unsigned int)count {
    if (!testDeferUnread) [testSessions[name] setM_uUnReadCount:@(count)];
    if (testSwitchInsideUnread) testAccount = [testAccount stringByAppendingString:@"-switched"];
}
@end

static void ActivityQueueTurns(NSUInteger remaining, dispatch_block_t completion) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (remaining > 1) ActivityQueueTurns(remaining - 1, completion);
        else completion();
    });
}

static void DrainActivity(void) {
    __block BOOL advanced = NO;
    ActivityQueueTurns(4, ^{ advanced = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!advanced && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    ActivityCheck(advanced, @"Activity main queue must advance before state assertions");
}

static ActivitySession *NewActivitySession(NSString *name, NSInteger unread) {
    ActivitySession *session = [ActivitySession new];
    session.m_nsUsrName = name;
    session.m_uUnReadCount = @(unread);
    session.m_uLastTime = floor(NSDate.date.timeIntervalSince1970);
    testSessions[name] = session;
    WCRInvalidateGroupIndex();
    return session;
}

static void TrackActivity(ActivitySession *session, WCRAFAccountContext *context) {
    ActivityCheck(WCRIsMessageActiveSession(session, session.m_nsUsrName, context), @"Unread row starts active");
    DrainActivity();
    ActivityCheck([WCRAFStore() hasTrackedMessageActivity:session.m_nsUsrName context:context],
        [@"Runtime persisted activity: " stringByAppendingString:session.m_nsUsrName]);
}

NSUInteger WCRRunActivityIntegrationTests(UIWindow *window) {
    UIViewController *savedRoot = window.rootViewController;
    testAccount = [@"activity-runtime-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSString *firstAccount = testAccount;
    testSessions = [NSMutableDictionary dictionary];
    NewMainFrameViewController *home = [NewMainFrameViewController new];
    window.rootViewController = home;
    [window layoutIfNeeded];
    ActivityCheck(WCRInstallCheckedHook(NewMainFrameViewController.class,
        @"tableView:didSelectRowAtIndexPath:", 'v', "@@", (IMP)hook_homeSelection,
        (IMP *)&orig_homeSelection), @"Install outer selection hook");
    ActivityCheck(WCRInstallCheckedHook(BaseMsgContentViewController.class,
        @"viewDidAppear:", 'v', "B", (IMP)hook_chatAppear, (IMP *)&orig_chatAppear), @"Install chat appearance hook");
    ActivityCheck(WCRInstallCheckedHook(MMNewSessionMgr.class,
        @"ChangeSessionUnReadCount:to:", 'v', "@I", (IMP)hook_sessionUnread,
        (IMP *)&orig_sessionUnread), @"Install verified unread ABI");
    WCRAFAccountContext *context = [WCRAFStore() currentContext];
    ActivityCheck([WCRAFStore() enableMessageActivityForContext:context], @"Enable runtime activity");
    hook_activeViewDidAppear(home, @selector(viewDidAppear:), NO);
    MMNewSessionMgr *manager = [MMNewSessionMgr new];

    // Same visible home, late native read: no new viewDidAppear or polling.
    ActivitySession *late = NewActivitySession(@"late-read", 3);
    TrackActivity(late, context);
    NSUInteger refreshes = home.refreshes;
    [manager ChangeSessionUnReadCount:late.m_nsUsrName to:0];
    DrainActivity();
    ActivityCheck(!WCRIsMessageActiveSession(late, late.m_nsUsrName, context), @"Late read event returns immediately");
    ActivityCheck(home.refreshes == refreshes + 1, @"Read event schedules one rebuild");
    NSUInteger lookups = testLookups;
    DrainActivity();
    ActivityCheck(testLookups == lookups && home.refreshes == refreshes + 1, @"Idle queues stop reading and refreshing");

    // Never trust a zero callback argument while fresh native state is unread.
    ActivitySession *delayed = NewActivitySession(@"native-still-unread", 2);
    TrackActivity(delayed, context);
    testDeferUnread = YES;
    [manager ChangeSessionUnReadCount:delayed.m_nsUsrName to:0];
    DrainActivity();
    ActivityCheck(WCRIsMessageActiveSession(delayed, delayed.m_nsUsrName, context), @"Unconfirmed callback cannot hide unread");
    testDeferUnread = NO;
    delayed.m_uUnReadCount = nil;
    WCRQueueNativeActivityEvent(delayed.m_nsUsrName, context);
    DrainActivity();
    ActivityCheck(WCRIsMessageActiveSession(delayed, delayed.m_nsUsrName, context), @"Unknown unread count stays visible");
    [manager ChangeSessionUnReadCount:delayed.m_nsUsrName to:0];
    DrainActivity();
    ActivityCheck(!WCRIsMessageActiveSession(delayed, delayed.m_nsUsrName, context), @"Later native confirmation returns");

    // The old alias receives row 99. The production outer hook captures row 0.
    ActivitySession *outgoing = NewActivitySession(@"outgoing-opened-from-home", 0);
    ActivitySession *other = NewActivitySession(@"other-outgoing", 0);
    [WCRAFStore() noteOutgoingMessage:outgoing.m_nsUsrName context:context lastMessageTime:outgoing.m_uLastTime];
    [WCRAFStore() noteOutgoingMessage:other.m_nsUsrName context:context lastMessageTime:other.m_uLastTime];
    home.testSession = outgoing;
    [home.testTable reloadData];
    [home.testTable layoutIfNeeded];
    NSIndexPath *row = [NSIndexPath indexPathForRow:0 inSection:0];
    ActivityCheck([home.testTable cellForRowAtIndexPath:row] != nil, @"Displayed home row exists");
    [home tableView:home.testTable didSelectRowAtIndexPath:row];
    DrainActivity();
    ActivityCheck(home.aliasCalls == 1, @"Native alias still runs once");
    ActivityCheck(!WCRIsMessageActiveSession(outgoing, outgoing.m_nsUsrName, context), @"Opening rendered row clears outgoing visit latch");
    ActivityCheck(WCRIsMessageActiveSession(other, other.m_nsUsrName, context), @"Translated index cannot read another conversation");

    // Sending a reply from that home-opened chat must not re-arm the visit latch.
    NSDictionary *wrap = @{@"m_n64MesSvrID": @0, @"m_nsFromUsr": testAccount,
        @"m_nsToUsr": outgoing.m_nsUsrName, @"m_uiCreateTime": @(outgoing.m_uLastTime)};
    WCRAFOutgoingTicket *ticket = WCRStageLocalSend(outgoing.m_nsUsrName, wrap);
    ActivityCheck(ticket && [objc_getAssociatedObject(ticket, kWCROutgoingHomeVisitKey) boolValue], @"Capture send origin before async acknowledgment");
    ActivityCheck(WCRRecordOutgoingActivity(ticket, outgoing.m_uLastTime), @"Record acknowledged home reply");
    WCRQueueNativeActivityEvent(outgoing.m_nsUsrName, context);
    DrainActivity();
    ActivityCheck(!WCRIsMessageActiveSession(outgoing, outgoing.m_nsUsrName, context), @"Reply does not become implicit Keep");

    testBypassAlias = YES;
    home.testSession = other;
    [home.testTable reloadData];
    [home.testTable layoutIfNeeded];
    [home tableView:home.testTable didSelectRowAtIndexPath:row];
    DrainActivity();
    ActivityCheck(home.aliasCalls == 1 && !WCRIsMessageActiveSession(other, other.m_nsUsrName, context), @"Direct chat open also clears visit latch");

    ActivitySession *held = NewActivitySession(@"explicitly-held", 1);
    [WCRAFStore() setHeld:YES username:held.m_nsUsrName context:context];
    [manager ChangeSessionUnReadCount:held.m_nsUsrName to:0];
    DrainActivity();
    ActivityCheck([WCRAFStore() isHeld:held.m_nsUsrName context:context], @"Read events preserve explicit Keep");
    ActivitySession *muted = NewActivitySession(@"muted", 4);
    muted.m_bShowUnReadAsRedDot = YES;
    WCRQueueNativeActivityEvent(muted.m_nsUsrName, context);
    DrainActivity();
    ActivityCheck(!WCRIsMessageActiveSession(muted, muted.m_nsUsrName, context) &&
        ![WCRAFStore() hasTrackedMessageActivity:muted.m_nsUsrName context:context], @"Muted rooms never auto-surface");
    ActivitySession *manual = NewActivitySession(@"manual-unread-return", 5);
    TrackActivity(manual, context);
    [WCRAFStore() setHeld:NO username:manual.m_nsUsrName context:context];
    WCRQueueNativeActivityEvent(manual.m_nsUsrName, context);
    DrainActivity();
    ActivityCheck([manual.m_uUnReadCount integerValue] == 5 &&
        !WCRIsMessageActiveSession(manual, manual.m_nsUsrName, context), @"Manual return keeps native unread and suppression");

    ActivitySession *covered = NewActivitySession(@"covered-home", 1);
    TrackActivity(covered, context);
    hook_activeViewWillDisappear(home, @selector(viewWillDisappear:), NO);
    window.rootViewController = [UIViewController new];
    [manager ChangeSessionUnReadCount:covered.m_nsUsrName to:0];
    DrainActivity();
    ActivityCheck(WCRIsMessageActiveSession(covered, covered.m_nsUsrName, context), @"Hidden home defers read return");
    refreshes = home.refreshes;
    WCRRefreshHomeProjection(nil, context);
    ActivityCheck(home.refreshes == refreshes + 1, @"Covered home controller can still invalidate its snapshot");
    window.rootViewController = home;
    [window layoutIfNeeded];
    hook_activeViewDidAppear(home, @selector(viewDidAppear:), NO);
    DrainActivity();
    ActivityCheck(!WCRIsMessageActiveSession(covered, covered.m_nsUsrName, context), @"Returning home reconciles known reads");

    // Repeated wakeups are coalesced; an inactive observation cannot erase the
    // fact that a displayed active row needs structural removal.
    ActivitySession *burst = NewActivitySession(@"coalesced-read", 1);
    TrackActivity(burst, context);
    burst.m_uUnReadCount = @0;
    refreshes = home.refreshes;
    lookups = testLookups;
    WCRScheduleActivityObservation(burst.m_nsUsrName, context, YES);
    for (NSUInteger i = 0; i < 100; i++) WCRScheduleActivityObservation(burst.m_nsUsrName, context, NO);
    DrainActivity();
    ActivityCheck(home.refreshes == refreshes + 1 && testLookups == lookups + 1, @"Burst is one native read and one rebuild");

    ActivitySession *switched = NewActivitySession(@"account-switch-event", 1);
    TrackActivity(switched, context);
    testSwitchInsideUnread = YES;
    [manager ChangeSessionUnReadCount:switched.m_nsUsrName to:0];
    DrainActivity();
    WCRAFAccountContext *newContext = [WCRAFStore() currentContext];
    ActivityCheck(![WCRAFStore() hasTrackedMessageActivity:switched.m_nsUsrName context:newContext] &&
        ![WCRAFStore() isMessageReturnSuppressed:switched.m_nsUsrName context:newContext
            lastMessageTime:switched.m_uLastTime], @"Old native event cannot write into new account");
    testSwitchInsideUnread = NO;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:
        [@"com.local.wcrefine.activefront.account.v2." stringByAppendingString:firstAccount]];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:
        [@"com.local.wcrefine.activefront.account.v2." stringByAppendingString:testAccount]];
    gWCRAppearedHomeController = nil;
    gWCRKnownHomeController = nil;
    gWCRHomeChatController = nil;
    gWCRHomeChatVisit = nil;
    gWCRPendingHomeVisit = nil;
    window.rootViewController = savedRoot;
    return activityChecks;
}
