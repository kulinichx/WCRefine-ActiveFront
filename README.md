# WCRefine Active Front v0.4

Target: WCRefine 2.1-2, rootless.

## Intended behavior

1. A friend/chat room that is not assigned to a WCRefine custom group remains a normal native WeChat home session.
2. An ungrouped friend/chat room gets an extra swipe action: **分组**.
3. A grouped friend/chat room with unread messages temporarily stays as a native WeChat home session.
4. If the user opens that surfaced session without choosing **保持**, unread clears; when returning home, WCRefine rebuilds the snapshot and collects the session back into its original group.
5. Before opening, swipe the surfaced grouped session and choose **保持**. It stays on the native WeChat home list even after being read.
6. A held grouped session gets **回组**. Choosing it clears only this tweak's Keep flag and lets WCRefine collect it back into its original group.
7. Surfaced/held rows keep WeChat's native ordering, pinning, preview, unread badge, draft behavior, etc.
8. WCRefine's old unread-message quick group is disabled.

## v0.4 compatibility change

v0.3 reused WCRefine's `homeGroupingExcludeSessions` as the Keep list. v0.4 no longer does that.

The Keep list is now stored independently under:

`com.local.wcrefine.activefront.heldUsernames.v1`

The patch hooks WCRefine's existing:

`-[WCRefineGroupDataProvider shouldExcludeNativeSessionFromGroupingForUnreadPolicy:]`

The original result is preserved. When WCRefine itself says a session should stay native because it is unread, v0.4 returns YES unchanged. If not unread, v0.4 additionally returns YES only when the username has our Keep flag and still belongs to a custom group.

This prevents **回组** from modifying the user's own WCRefine "exclude sessions" configuration.

## Group assignment

The extra **分组** action is shown only for friend/chat-room native rows that are currently not in a WCRefine custom group.

Choosing a group is treated as an exclusive move among custom groups:

- remove from other custom groups;
- add to selected custom group;
- clear stale Active Front Keep state;
- refresh WCRefine home projection.

## Build

Requires rootless Theos + iOS SDK:

```sh
make clean package
```

## First-device test order

Test these in order so a failure can be isolated quickly:

1. Launch WeChat and verify WCRefine itself still loads normally.
2. Verify the old unread quick group is disabled.
3. Use an **ungrouped** friend: swipe left -> **分组** should appear and the group picker should list groups of matching scope.
4. Assign that friend to a group and confirm the normal home row disappears after refresh if it has no unread message.
5. Send a new message to that grouped friend. It should surface as a normal native WeChat row.
6. Open it directly without **保持**, read it, return home. It should return to its original group.
7. Send another message. Before opening, swipe -> **保持**. Open/read/return. It should remain on home.
8. Swipe the held row -> **回组**. With no unread messages it should disappear from native home and return to its original group.
9. Repeat steps 5-8 with a chat room.
10. Surface multiple conversations and verify their order is controlled by WeChat, not by this patch.

## Deliberately not addressed yet

The existing WCRefine group-row tap/highlight visual-feedback issue is not changed in this branch. It remains the final task after Active Front behavior is stable.
