# WCRefine Group v1.2 (TrollStore)


## v1.2 device fix

- Fixed the missing **分组 / 保持 / 回组** swipe action caused by hard-coding WCRefine group scopes to only `1` and `2`.
- WCRefine 2.1-2 uses additional scope values/bitmasks; v1.2 now asks WCRefine for the actual scope and only offers **分组** when a matching custom group exists.
- WCRefine-created group rows keep their existing long-press menu untouched.
- The injected library is now named **`WCRefineGroup.dylib`**.
- Added concise swipe diagnostics with username/scope/group count for the next device test.

## v1.1 compile fix

- Removed the deprecated `UITableViewRowAction` / `editActionsForRowAtIndexPath:` compatibility path.
- ActiveFront now adds its dynamic **分组 / 保持 / 回组** action only through WCRefine's modern `UISwipeActionsConfiguration` hook.
- WCRefine's existing trailing swipe actions are preserved and appended after the ActiveFront action.
- Full-swipe execution is disabled for the merged configuration to avoid accidental **分组 / 保持 / 回组** activation.
- `-Werror` remains enabled; the build is fixed at the source level rather than suppressing deprecation diagnostics.

Target: a TrollStore-installed/injected WeChat build where **WCRefine 2.1-2 is already embedded and working**.

## Responsibility split

WCRefine remains the grouping engine. ActiveFront does not replace or rewrite its group database.

WCRefine continues to own:

- custom friend/chat-room groups;
- group creation, deletion, renaming and membership;
- its original unread-message feature and its on/off state;
- the rest of WCRefine's grouping UI/settings.

ActiveFront only adds the home-list projection behavior:

1. A real new message for an already-grouped friend/chat room marks that session **Surfaced**.
2. Surfaced sessions remain native WeChat rows, so WeChat keeps its own ordering, pinning, message preview, unread badge/red dot and drafts.
3. Open/read a Surfaced session without choosing **保持** -> Surfaced clears and the next WCRefine projection returns it to its original group.
4. Swipe **保持** before opening -> persistent **Held** keeps it on the native home list after read.
5. Swipe a Held row -> **回组** clears Held plus the current Surfaced state; group membership itself never changes.
6. An ungrouped friend/chat room remains a normal WeChat row and gets a swipe action **分组**.

## WCRefine unread-message feature

v1.1 deliberately **does not enable, disable, delete, or rewrite** WCRefine's own unread-message group/settings.

For the clean ActiveFront experience we currently recommend testing with WCRefine's unread-message group turned off. If the user turns WCRefine's unread feature back on, its original unread policy is allowed to continue running; ActiveFront does not silently change that preference.

Internally, ActiveFront only makes WCRefine's per-session projection predicate available while ActiveFront has Surfaced/Held state (plus a short startup recovery window). Outside those cases the original WCRefine getter result is returned unchanged.

## Packaging model

This is an **app-injection dylib**, not a RootHide/rootless jailbreak package.

- arm64;
- no `/var/jb` dependency;
- no RootHide `.jbroot` dependency;
- no `control` or MobileSubstrate filter plist;
- no static Substrate link;
- resolves `MSHookMessageEx` dynamically from the CydiaSubstrate compatibility framework already loaded by the WCRefine-injected WeChat build.

If WCRefine or `MSHookMessageEx` is unavailable, ActiveFront does not install its hooks.

## Local repository workflow (Windows + Git Bash)

Windows only needs Git for normal source management:

```sh
git checkout feature/active-front
git status
git add .
git commit -m "feat: preserve WCRefine unread settings"
```

Compilation is intended to run in GitHub Actions.

## GitHub Actions

The included `.github/workflows/build-dylib.yml` uses a macOS 14 GitHub runner and runs on pushes to `feature/active-front` or manually with `workflow_dispatch`.

It:

1. checks out Theos on a macOS 14 runner;
2. uses the Xcode-provided iPhoneOS SDK rather than a separate Linux cross-toolchain;
3. builds the project as arm64;
4. finds `WCRefineGroup.dylib`;
5. records Mach-O header, linked dependencies, undefined symbols and SHA-256;
6. uploads all of those files as one Actions artifact.

The workflow is intentionally compile-only. It does not modify a WeChat IPA/TIPA yet. The first CI run is meant to validate compilation and linkage before app injection is automated.

## v1.1 runtime diagnostics

The dylib now emits concise `NSLog` lines prefixed with `WCRefineActiveFront 1.2` for:

- dylib constructor/load;
- successful resolution of `MSHookMessageEx`;
- hook installation success or timeout;
- grouped incoming message -> Surfaced;
- read -> Surfaced cleared;
- swipe Keep / Return-to-group;
- assigning an ungrouped session to a WCRefine group.

These logs are for the first device validation. They do not change WCRefine's group data model or native WeChat ordering.

## Intended app layout

Conceptually:

```text
Payload/WeChat.app/
  WeChat
  Frameworks/
    CydiaSubstrate.framework/...
    WCRefine.dylib
    WCRefineGroup.dylib
```

The final TIPA workflow should preserve the load-command/layout conventions used by the already-working WCRefine-injected WeChat package.

## First device test order

1. Confirm the current TrollStore WeChat + WCRefine build works unchanged.
2. Turn off WCRefine's unread-message group for the initial ActiveFront test.
3. Add only `WCRefineGroup.dylib` and its load command.
4. Test ungrouped friend -> swipe **分组**.
5. Test ungrouped group chat -> swipe **分组**.
6. Grouped friend receives a real message -> native row surfaces.
7. Open directly -> read -> return -> row goes back to its original group.
8. Receive again -> swipe **保持** before opening -> read -> return -> row remains native.
9. Swipe held row -> **回组** -> row returns to group.
10. Repeat with group chats and muted/red-dot chats.
11. Verify native WeChat ordering is unchanged.
12. Optionally re-enable WCRefine's unread feature and observe coexistence behavior; ActiveFront must not alter its saved setting.

## Deferred

The pre-existing WCRefine group-row tap/highlight visual-feedback issue remains intentionally untouched until ActiveFront is stable.
