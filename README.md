# WCRefine Active Front patch (prototype v0.3)

Target: WCRefine 2.1-2, rootless.

## Behavior

- Grouped friend/chat room + unread message: temporarily remains as a native WeChat home session.
- Open/read without choosing Keep: after unread clears and home refreshes, WCRefine collects it back into its original group.
- Before opening, swipe left and choose **保持**: session is added to WCRefine's existing `homeGroupingExcludeSessions`, so it stays native on home after being read.
- Held session: swipe left and choose **回组** to remove it from that exclusion list.
- Ungrouped friend/chat room: retains native WeChat behavior; swipe left shows **分组**, then choose an existing WCRefine custom group.
- Old `wcrefine_quick_unread` group is disabled because unread sessions are surfaced directly.
- Native WeChat ordering is not replaced by this patch.

## Important design choice

This patch does not create a second grouping database. It reuses three existing WCRefine mechanisms discovered in the 2.1-2 binary:

- `homeGroupingExcludeUnreadEnabled` -> temporary unread surfacing.
- `homeGroupingExcludeSessions` -> persistent Keep state.
- `WCRefineGroupManager addMember:toGroup:` -> group assignment.

## Build

Requires a rootless Theos toolchain with an iOS SDK:

```sh
make package
```

The current analysis environment does not contain a usable iOS SDK/Theos installation, so this folder is source-complete but not compiled here.

## Test order

1. Launch WeChat and confirm the old unread group is hidden.
2. Send a message to a grouped friend: the friend should appear as a native home row.
3. Open it without Keep, return home: it should be back inside its original group.
4. Repeat, but swipe **保持** before opening: after reading it should remain on home.
5. Swipe the held row and choose **回组**: it should return to its original group.
6. For an ungrouped friend/chat room, swipe and choose **分组**: choose a matching group and confirm membership.
7. Verify multiple surfaced/held rows are ordered by WeChat itself.

The existing "group row cannot be tapped" WCRefine bug is intentionally not addressed in this patch yet.


## v0.2 static compatibility update

- Hooks both WCRefine swipe paths: modern `UISwipeActionsConfiguration` and legacy `UITableViewRowAction`.
- Keeps the original WCRefine swipe actions and appends one dynamic action: `分组` / `保持` / `回组`.
- No changes to the known group-row tap/highlight issue.

## Reverse-engineering checks for WCRefine 2.1-2

- `homeGroupingExcludeUnreadEnabled` is read while WCRefine builds the home grouping snapshot. When `shouldExcludeNativeSessionFromGroupingForUnreadPolicy:` returns true, that native session skips the group-collection path and remains in the WeChat home list.
- `groupScopeForNativeSession:` returns scope `2` for usernames ending in `@chatroom` / `@im.chatroom`, and scope `1` for normal single-chat sessions; these are the two scopes patched here.
- `homeGroupingExcludeSessions` is converted into a set during snapshot construction and is suitable for the explicit Keep/Return state.


## v0.3 behavior refinement

- The **分组** action now behaves as an exclusive move among WCRefine custom groups: it removes the conversation from other custom groups before adding it to the selected one.
- Assigning a conversation to a group also clears any stale **保持** state, while unread surfacing still keeps a newly active conversation visible until it is read.
- The known group-row tap/highlight visual issue remains intentionally untouched.
