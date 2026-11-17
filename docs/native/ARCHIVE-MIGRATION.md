# Native archive migration audit

Baseline: `14aa30b`, before candidate 7. Source locations below refer to that
commit unless labelled migrated. This is a source audit, not runtime, linker,
compilation or test evidence. No tests were run or edited for this audit.

Proposed glossary term: **Native module** — A cohesive native capability with an
explicit interface through which other capabilities use it.

## Import graph and header boundary

There are 14 native directories (nine app, five helper), plus the app entry
point. The declared graph preserves existing mutual dependencies; the migration
does not repair them. Arrows below mean actual quoted imports/includes, not
runtime calls or forward declarations.

Baseline inventory from `/tmp/arch-archives-investigation.txt`:

```text
native/app/Canvas: public 7, private 7; imports native/app/Controller, native/app/Support, native/app/System
  public: DWCanvasRenderer.h DWMacWallpaperCache.h DWMacWallpaperRefresh.h DWFrameDriver.h DWCanvasAttachment.h DWCanvasCursor.h IFBackground.h
  private: IFBGTiffSource.h DWMetalSupport.h IFBGShaderDecl.h IFCompositor+Private.h IFCompositor.h DWCanvasRenderer+Private.h IFBackground+Private.h
native/app/CompositorMode: public 14, private 8; imports native/app/Canvas, native/app/Controller, native/app/Navigation, native/app/Support, native/dock-helper/Client
  public: DWNativeReplicaFamilies.h DWNativeReplicaInput.h DWNativeTabletRouter.h DWNativeRelativeMotion.h DWNativeTransition.h DWNativeDragTakeover.h DWNativePresenter.h DWNativePointerGrab.h DWNativeWindowServer.h DWNativeFamily.h DWNativeDecorations.h DWNativeViews.h DWNativePlacementValidation.h DWNativeResizePresentation.h
  private: DWReplicaOrder.h DWNativeReplicaFamilies+Private.h DWNativeDisplaySpace.h DWReplicaMember.h DWNativePresenter+Private.h DWWindowServerFamily.h DWReplicaRecovery.h DWNativeToolbarExtent.h
native/app/Controller: public 52, private 5; imports native/app/Navigation, native/app/Support
  public: DWSourceBinding.h DWWindowRule.h DWScene.h DWCornerActions.h DWMetadata.h DWRender.h DWSizeEffect.h DWModifiers.h DWFocus.h DWPin.h DWNavigationContext.h DWEffect.h DWHotCornerSettings.h DWLifecycle.h DWRenderBackground.h DWResizeBorder.h DWPointerDemand.h DWHit.h DWRenderOutline.h DWNavigation.h DWPlacement.h DWResizeTransaction.h DWScreenshotWindowTarget.h DWScreenshotTarget.h DWPointerSettings.h DWController+External.h DWWindow.h DWNativeResult.h DWControllerValue.h DWOutput.h DWFocusEffect.h DWRenderChrome.h DWSceneWriter.h DWShellEffect.h DWSource.h DWDecoration.h DWController.h DWScreenshotRegionTarget.h DWGestureAction.h DWBinding.h DWLifecycleEvent.h DWFlight.h DWControllerReply.h DWGestureState.h DWController+Focus.h DWFullscreen.h DWDrawnValue.h DWRGBA.h DWIdentity.h DWFocusCorrection.h DWRenderEffects.h DWControllerNative.h
  private: DWScene+Private.h DWSnapshotMirror.h DWProjectedArray.h DWController+Private.h DWBackingArray.h
native/app/Desktop: public 9, private 11; imports native/app/Canvas, native/app/CompositorMode, native/app/Controller, native/app/Input, native/app/Navigation, native/app/Support, native/app/System, native/app/Windows
  public: LiveSource.h DWCaptureConfiguration.h DWChildProcess.h DWPressAdmission.h DWRootCaptureMailbox.h DWPressPairing.h Desktop.h DWDesktopSupport.h Router.h
  private: DWControllerHit.h Desktop+Private.h DWPressGesture.h DWExportFrame.h CanvasPanel.h DesktopView.h DWPressSceneAdapter.h FlippedView.h FixtureWindow.h DWPressNativeAdapter.h DesktopPanel.h
native/app/Input: public 12, private 0; imports native/app/CompositorMode, native/app/Controller, native/app/Desktop, native/app/Support
  public: DWDockGuard.h DWTrackpadGestureEvent.h DWPointerHover.h DWTapKeys.h DWTrackpadGestures.h DWNativeInput.h DWHotKeys.h DWMultitouchSource.h DWCycleHold.h DWInputSources.h DWDockControl.h DWHotCorners.h
  private:
native/app/Navigation: public 8, private 0; imports native/app/CompositorMode, native/app/Controller, native/app/Desktop, native/app/Support
  public: DWResizeCoordinator.h DWNativeResizeDriver.h DWSizeTransitionHost.h DWNativeResize.h DWNativeFocusDriver.h DWNavigationCoordinator.h DWNativeFocus.h DWSizeTransition.h
  private:
native/app/Support: public 5, private 0; imports
  public: DWTypedValue.h DWAXLookup.h DWDebugTrace.h DWGeometryJSON.h DWOwnerFile.h
  private:
native/app/System: public 15, private 1; imports native/app/Support, native/dock-helper/Daemon, native/dock-helper/Lifecycle, native/dock-helper/Loader
  public: DWUpdateCheck.h DWSetupAssistant.h DWDockReloader.h DWIPCServer.h DWInstall.h DWLoginItem.h DWSystemTakeover.h DWSetupState.h DWConfigWatcher.h DWScreenshotWriter.h DWOnboarding.h DWSessionWatch.h DWNativeDesktopCLI.h DWLoaderService.h DWUninstall.h
  private: DWSetupButton.h
native/app/Windows: public 5, private 7; imports native/app/CompositorMode, native/app/Navigation, native/app/Support
  public: DWWindowManager.h DWPanLaunch.h DWWindowEvents.h DWWindowCandidate.h DWWindowObserver.h
  private: DWObservedWindow.h DWApplicationCatalogWatch.h DWObservedApplication.h DWApplicationWatch.h DWApplicationMetadata.h DWWindowManager+Private.h DWWindowEvents+Private.h
native/app/main.m: public 0, private 0; imports native/app/Desktop, native/app/Navigation, native/app/Support, native/app/System
  public:
  private:
native/dock-helper/Client: public 3, private 0; imports
  public: DWHelperProtocol.h DWJournalFields.h DWHelperClient.h
  private:
native/dock-helper/Daemon: public 1, private 0; imports native/dock-helper/Lifecycle, native/dock-helper/Loader
  public: DWLoaddRequest.h
  private:
native/dock-helper/Lifecycle: public 2, private 1; imports native/app/Support, native/dock-helper/Client
  public: DWHelperLifecycle.h DWHelperLauncher.h
  private: DWHelperMacEnvironment.h
native/dock-helper/Loader: public 2, private 0; imports native/dock-helper/Client, native/dock-helper/Lifecycle
  public: DWStagedPayload.h DWPreflight.h
  private:
native/dock-helper/Payload: public 0, private 0; imports native/dock-helper/Client
  public:
  private:
```

### Cyclic app imports

The sole nontrivial strongly connected component is Canvas, CompositorMode,
Controller, Desktop, Input, Navigation and Windows. Its 19 directed edge kinds
contain 145 individual imports. Every edge below participates in a directed
cycle because both endpoints are in that SCC. All individual imports are
listed, including those in private headers. The target identifies the exact
header; its basename is the quoted include operand. Private source headers gain
`Private/` in the migration; baseline source locations remain unchanged here.

#### Canvas → Controller

```text
native/app/Canvas/DWCanvasRenderer.h:6 -> native/app/Controller/DWScene.h
```

#### CompositorMode → Canvas

```text
native/app/CompositorMode/DWNativeReplicaFamilies.h:3 -> native/app/Canvas/DWCanvasAttachment.h
native/app/CompositorMode/DWReplicaMember.h:7 -> native/app/Canvas/DWCanvasAttachment.h
```

#### CompositorMode → Controller

```text
native/app/CompositorMode/DWNativeViews.m:3 -> native/app/Controller/DWScene.h
native/app/CompositorMode/DWNativePresenter+Frames.m:10 -> native/app/Controller/DWScene.h
native/app/CompositorMode/DWNativePresenter.h:3 -> native/app/Controller/DWScene.h
native/app/CompositorMode/DWNativeViews.h:3 -> native/app/Controller/DWScene.h
native/app/CompositorMode/DWNativeResizePresentation.h:5 -> native/app/Controller/DWController.h
```

#### CompositorMode → Navigation

```text
native/app/CompositorMode/DWNativePresenter.h:6 -> native/app/Navigation/DWNativeResize.h
native/app/CompositorMode/DWNativeReplicaInput.m:10 -> native/app/Navigation/DWNativeFocus.h
native/app/CompositorMode/DWNativeResizePresentation.h:4 -> native/app/Navigation/DWNavigationCoordinator.h
native/app/CompositorMode/DWNativePresenter.m:10 -> native/app/Navigation/DWNativeFocus.h
native/app/CompositorMode/DWNativeDecorations.m:7 -> native/app/Navigation/DWNativeFocus.h
```

#### Controller → Navigation

```text
native/app/Controller/DWNativeResult.h:4 -> native/app/Navigation/DWNativeResize.h
```

#### Desktop → Canvas

```text
native/app/Desktop/Desktop+Rendering.m:7 -> native/app/Canvas/DWMacWallpaperCache.h
native/app/Desktop/Desktop+Rendering.m:8 -> native/app/Canvas/DWMacWallpaperRefresh.h
native/app/Desktop/Desktop+Private.h:15 -> native/app/Canvas/IFBackground.h
native/app/Desktop/Desktop.h:9 -> native/app/Canvas/DWCanvasRenderer.h
native/app/Desktop/Desktop.h:10 -> native/app/Canvas/DWCanvasCursor.h
native/app/Desktop/Desktop.h:15 -> native/app/Canvas/DWFrameDriver.h
```

#### Desktop → CompositorMode

```text
native/app/Desktop/DesktopView.m:10 -> native/app/CompositorMode/DWNativeFamily.h
native/app/Desktop/DWPressNativeAdapter.m:3 -> native/app/CompositorMode/DWNativeDecorations.h
native/app/Desktop/DWPressNativeAdapter.m:4 -> native/app/CompositorMode/DWNativeReplicaInput.h
native/app/Desktop/DWPressNativeAdapter.m:6 -> native/app/CompositorMode/DWNativePlacementValidation.h
native/app/Desktop/DWPressNativeAdapter.m:7 -> native/app/CompositorMode/DWNativeWindowServer.h
native/app/Desktop/DWPressNativeAdapter.m:9 -> native/app/CompositorMode/DWNativeFamily.h
native/app/Desktop/DWExportFrame.h:7 -> native/app/CompositorMode/DWNativePresenter.h
native/app/Desktop/DesktopView+Pointer.m:6 -> native/app/CompositorMode/DWNativeFamily.h
native/app/Desktop/Desktop+Chooser.m:9 -> native/app/CompositorMode/DWNativeFamily.h
native/app/Desktop/Desktop+Visibility.m:9 -> native/app/CompositorMode/DWNativeFamily.h
native/app/Desktop/Desktop+Navigation.m:8 -> native/app/CompositorMode/DWNativeFamily.h
native/app/Desktop/Desktop.h:21 -> native/app/CompositorMode/DWNativePresenter.h
native/app/Desktop/Desktop.h:22 -> native/app/CompositorMode/DWNativePointerGrab.h
native/app/Desktop/Desktop.h:23 -> native/app/CompositorMode/DWNativeRelativeMotion.h
native/app/Desktop/Desktop.h:24 -> native/app/CompositorMode/DWNativeReplicaFamilies.h
native/app/Desktop/Desktop.h:26 -> native/app/CompositorMode/DWNativeTabletRouter.h
native/app/Desktop/Desktop.h:27 -> native/app/CompositorMode/DWNativeTransition.h
native/app/Desktop/Desktop.h:29 -> native/app/CompositorMode/DWNativeViews.h
native/app/Desktop/Desktop+Input.m:11 -> native/app/CompositorMode/DWNativeDecorations.h
native/app/Desktop/Desktop+Input.m:12 -> native/app/CompositorMode/DWNativePlacementValidation.h
native/app/Desktop/Desktop+Input.m:13 -> native/app/CompositorMode/DWNativeReplicaInput.h
native/app/Desktop/Desktop+Input.m:14 -> native/app/CompositorMode/DWNativeFamily.h
native/app/Desktop/Desktop+Input.m:15 -> native/app/CompositorMode/DWNativeDragTakeover.h
native/app/Desktop/Desktop+Windows.m:9 -> native/app/CompositorMode/DWNativeFamily.h
native/app/Desktop/Desktop+Capture.m:7 -> native/app/CompositorMode/DWNativeFamily.h
native/app/Desktop/Desktop+CapturedInput.m:10 -> native/app/CompositorMode/DWNativeDecorations.h
native/app/Desktop/Desktop+CapturedInput.m:11 -> native/app/CompositorMode/DWNativePlacementValidation.h
native/app/Desktop/Desktop+CapturedInput.m:12 -> native/app/CompositorMode/DWNativeReplicaInput.h
native/app/Desktop/Desktop+CapturedInput.m:13 -> native/app/CompositorMode/DWNativeFamily.h
native/app/Desktop/Desktop+CapturedInput.m:14 -> native/app/CompositorMode/DWNativeDragTakeover.h
native/app/Desktop/DWPressAdmission.m:9 -> native/app/CompositorMode/DWNativeDecorations.h
native/app/Desktop/DWPressAdmission.m:10 -> native/app/CompositorMode/DWNativePlacementValidation.h
native/app/Desktop/DWPressAdmission.m:11 -> native/app/CompositorMode/DWNativeReplicaInput.h
native/app/Desktop/DWPressAdmission.m:12 -> native/app/CompositorMode/DWNativeFamily.h
native/app/Desktop/DWPressAdmission.m:13 -> native/app/CompositorMode/DWNativeDragTakeover.h
native/app/Desktop/DWPressPairing.m:6 -> native/app/CompositorMode/DWNativeTabletRouter.h
native/app/Desktop/Desktop+Hover.m:7 -> native/app/CompositorMode/DWNativePlacementValidation.h
native/app/Desktop/DesktopView+Scroll.m:10 -> native/app/CompositorMode/DWNativeFamily.h
```

#### Desktop → Controller

```text
native/app/Desktop/DWControllerHit.h:3 -> native/app/Controller/DWScene.h
native/app/Desktop/Desktop+Private.h:18 -> native/app/Controller/DWControllerNative.h
native/app/Desktop/DWPressAdmission.h:4 -> native/app/Controller/DWController.h
native/app/Desktop/Desktop+IPC.m:5 -> native/app/Controller/DWController+External.h
native/app/Desktop/Desktop.h:34 -> native/app/Controller/DWSceneWriter.h
native/app/Desktop/Desktop.h:40 -> native/app/Controller/DWController.h
native/app/Desktop/Desktop.h:41 -> native/app/Controller/DWController+Focus.h
```

#### Desktop → Input

```text
native/app/Desktop/Desktop+Gestures.m:6 -> native/app/Input/DWDockControl.h
native/app/Desktop/Desktop.m:9 -> native/app/Input/DWInputSources.h
native/app/Desktop/Desktop+IPC.m:6 -> native/app/Input/DWInputSources.h
native/app/Desktop/DesktopView.h:5 -> native/app/Input/DWPointerHover.h
native/app/Desktop/Desktop.h:12 -> native/app/Input/DWCycleHold.h
native/app/Desktop/Desktop.h:13 -> native/app/Input/DWDockGuard.h
native/app/Desktop/Desktop.h:16 -> native/app/Input/DWNativeInput.h
native/app/Desktop/Desktop.h:17 -> native/app/Input/DWHotCorners.h
native/app/Desktop/Desktop.h:18 -> native/app/Input/DWHotKeys.h
native/app/Desktop/Desktop.h:20 -> native/app/Input/DWMultitouchSource.h
native/app/Desktop/Desktop.h:36 -> native/app/Input/DWTapKeys.h
native/app/Desktop/Desktop.h:37 -> native/app/Input/DWTrackpadGestures.h
native/app/Desktop/Desktop+Input.m:8 -> native/app/Input/DWDockControl.h
native/app/Desktop/Desktop+CapturedInput.m:7 -> native/app/Input/DWDockControl.h
native/app/Desktop/Desktop+Bindings.m:5 -> native/app/Input/DWInputSources.h
native/app/Desktop/Desktop+Config.m:5 -> native/app/Input/DWInputSources.h
native/app/Desktop/DWPressAdmission.m:6 -> native/app/Input/DWDockControl.h
native/app/Desktop/DWPressPairing.m:4 -> native/app/Input/DWNativeInput.h
native/app/Desktop/DWPressPairing.m:5 -> native/app/Input/DWTrackpadGestures.h
native/app/Desktop/Desktop+Actions.m:5 -> native/app/Input/DWInputSources.h
```

#### Desktop → Navigation

```text
native/app/Desktop/DWPressNativeAdapter.m:5 -> native/app/Navigation/DWNativeFocus.h
native/app/Desktop/DWPressAdmission.h:3 -> native/app/Navigation/DWNativeResize.h
native/app/Desktop/Desktop+IPC.m:8 -> native/app/Navigation/DWNativeFocus.h
native/app/Desktop/Desktop+Chooser.m:7 -> native/app/Navigation/DWNativeFocus.h
native/app/Desktop/Desktop+Visibility.m:7 -> native/app/Navigation/DWNativeFocus.h
native/app/Desktop/Desktop+Navigation.m:6 -> native/app/Navigation/DWNativeFocus.h
native/app/Desktop/Desktop+Navigation.m:7 -> native/app/Navigation/DWNativeFocusDriver.h
native/app/Desktop/Desktop.h:25 -> native/app/Navigation/DWNativeResizeDriver.h
native/app/Desktop/Desktop.h:28 -> native/app/Navigation/DWSizeTransition.h
native/app/Desktop/Desktop.h:31 -> native/app/Navigation/DWNavigationCoordinator.h
native/app/Desktop/Desktop.h:33 -> native/app/Navigation/DWResizeCoordinator.h
native/app/Desktop/Desktop+Input.m:9 -> native/app/Navigation/DWNativeFocus.h
native/app/Desktop/Desktop+Windows.m:7 -> native/app/Navigation/DWNativeFocus.h
native/app/Desktop/Desktop+CapturedInput.m:8 -> native/app/Navigation/DWNativeFocus.h
native/app/Desktop/Desktop+Bindings.m:7 -> native/app/Navigation/DWNativeFocus.h
native/app/Desktop/Desktop+Config.m:7 -> native/app/Navigation/DWNativeFocus.h
native/app/Desktop/DWPressAdmission.m:7 -> native/app/Navigation/DWNativeFocus.h
native/app/Desktop/DWPressAdmission.m:14 -> native/app/Navigation/DWNativeResize.h
native/app/Desktop/Desktop+Actions.m:7 -> native/app/Navigation/DWNativeFocus.h
```

#### Desktop → Windows

```text
native/app/Desktop/DesktopView.m:9 -> native/app/Windows/DWWindowEvents.h
native/app/Desktop/DWPressNativeAdapter.m:10 -> native/app/Windows/DWWindowEvents.h
native/app/Desktop/Desktop+IPC.m:9 -> native/app/Windows/DWWindowEvents.h
native/app/Desktop/Desktop+Chooser.m:8 -> native/app/Windows/DWWindowEvents.h
native/app/Desktop/Desktop+Visibility.m:8 -> native/app/Windows/DWWindowEvents.h
native/app/Desktop/Desktop.h:32 -> native/app/Windows/DWPanLaunch.h
native/app/Desktop/Desktop.h:38 -> native/app/Windows/DWWindowManager.h
native/app/Desktop/Desktop.h:39 -> native/app/Windows/DWWindowObserver.h
native/app/Desktop/Desktop+Input.m:10 -> native/app/Windows/DWWindowEvents.h
native/app/Desktop/Desktop+Windows.m:8 -> native/app/Windows/DWWindowEvents.h
native/app/Desktop/Desktop+Capture.m:6 -> native/app/Windows/DWWindowEvents.h
native/app/Desktop/Desktop+CapturedInput.m:9 -> native/app/Windows/DWWindowEvents.h
native/app/Desktop/Desktop+Bindings.m:8 -> native/app/Windows/DWWindowEvents.h
native/app/Desktop/Desktop+Config.m:8 -> native/app/Windows/DWWindowEvents.h
native/app/Desktop/DWPressAdmission.m:8 -> native/app/Windows/DWWindowEvents.h
native/app/Desktop/Desktop+Hover.m:6 -> native/app/Windows/DWWindowEvents.h
native/app/Desktop/DesktopView+Scroll.m:9 -> native/app/Windows/DWWindowEvents.h
native/app/Desktop/Desktop+Actions.m:8 -> native/app/Windows/DWWindowEvents.h
```

#### Input → CompositorMode

```text
native/app/Input/DWNativeInput.m:7 -> native/app/CompositorMode/DWNativeTabletRouter.h
```

#### Input → Controller

```text
native/app/Input/DWPointerHover.h:3 -> native/app/Controller/DWController.h
native/app/Input/DWHotCorners.m:11 -> native/app/Controller/DWHotCornerSettings.h
native/app/Input/DWHotCorners.m:12 -> native/app/Controller/DWCornerActions.h
native/app/Input/DWHotKeys.m:4 -> native/app/Controller/DWControllerReply.h
native/app/Input/DWTapKeys.m:10 -> native/app/Controller/DWControllerReply.h
```

#### Input → Desktop

```text
native/app/Input/DWNativeInput.m:3 -> native/app/Desktop/DWPressPairing.h
```

#### Navigation → CompositorMode

```text
native/app/Navigation/DWSizeTransition.m:8 -> native/app/CompositorMode/DWNativeFamily.h
native/app/Navigation/DWSizeTransition.m:10 -> native/app/CompositorMode/DWNativeResizePresentation.h
native/app/Navigation/DWSizeTransitionHost.h:2 -> native/app/CompositorMode/DWNativeResizePresentation.h
native/app/Navigation/DWSizeTransitionHost.h:4 -> native/app/CompositorMode/DWNativeViews.h
```

#### Navigation → Controller

```text
native/app/Navigation/DWResizeCoordinator.h:3 -> native/app/Controller/DWController.h
native/app/Navigation/DWNavigationCoordinator.h:3 -> native/app/Controller/DWController+Focus.h
```

#### Navigation → Desktop

```text
native/app/Navigation/DWSizeTransition.m:4 -> native/app/Desktop/DWDesktopSupport.h
native/app/Navigation/DWSizeTransition.m:5 -> native/app/Desktop/LiveSource.h
```

#### Windows → CompositorMode

```text
native/app/Windows/DWWindowManager+Discovery.m:18 -> native/app/CompositorMode/DWNativeFamily.h
native/app/Windows/DWWindowObserver.m:4 -> native/app/CompositorMode/DWNativePresenter.h
native/app/Windows/DWWindowObserver.m:5 -> native/app/CompositorMode/DWNativeFamily.h
native/app/Windows/DWWindowManager.m:18 -> native/app/CompositorMode/DWNativeFamily.h
```

#### Windows → Navigation

```text
native/app/Windows/DWWindowManager+Discovery.m:19 -> native/app/Navigation/DWNativeFocus.h
native/app/Windows/DWWindowObserver.m:3 -> native/app/Navigation/DWNativeFocus.h
native/app/Windows/DWWindowManager.m:19 -> native/app/Navigation/DWNativeFocus.h
native/app/Windows/DWWindowEvents+Private.h:16 -> native/app/Navigation/DWNativeFocus.h
```

### Public only because internal coupling crosses a directory

“Public” in this mechanical split means cross-directory reachable, not a
stability promise. Known leaks remain at the module root:

| Header | Baseline consumer | Why this is a leak |
| --- | --- | --- |
| `Desktop/DWPressPairing.h` | `Input/DWNativeInput.m:3` | Its comment calls it the private physical-pair/tombstone implementation of press admission; the tap constructs/forwards to it. |
| `Desktop/LiveSource.h` | `Navigation/DWSizeTransition.m:5` | Mutable capture-stream, ownership and presentation records escape the Desktop boundary. |
| `Desktop/DWDesktopSupport.h` | `Navigation/DWSizeTransition.m:4`, `app/main.m:5` | Shell stop state and inline process/window/event-loop helpers escape Desktop. |
| `Controller/DWSceneWriter.h` | `Desktop/Desktop.h:34` | Baseline imports the Rust header into a public filesystem-work interface, leaking a transitive dependency. The migration replaces this with an opaque typedef. |

Other root headers such as `DWSizeTransitionHost.h`, `DWController+Focus.h` and
`DWCanvasAttachment.h` are intentionally shared interfaces. Cross-directory use
alone does not imply they should be private. Classification by reachability is
not an architecture endorsement. No coupling repair is part of this audit.

## Objective-C registration and archive order

A comment/string-aware scan of baseline `native/**/*.m` found **2,101 explicit
method definitions and 2,101 unique (receiver, instance/class kind, selector)
keys**. There are no duplicate definitions to list: primary/primary,
primary/category and category/category collision sets are all empty, across
app and helper. The scan accepts only implementation-scope method bodies, not
declarations. It balances return-type parentheses, including both block-returning
getters in `Input/DWNativeInput.m`. A separate source search found no methods on
the same line as an `@implementation` directive.

No explicit `+load` exists. The only constructor attribute is
`native/dock-helper/Payload/DWPayload.m:484`, `productionStart`. Payload fragments
remain textual imports in their existing order, never additional independent
objects. No method swizzling or `class_addMethod`/`class_replaceMethod` call was
found under `native/`.

There is consequently no source-defined category override whose “last category
wins” behaviour needs preserving. This is not a claim about inherited framework
methods, binary layout, constructor timing relative to system libraries or
compiler-synthesized property methods (not explicit bodies in this count).
Preserve all objects through per-archive force loading and preserve Payload
fragment order. Compare final symbols/classes/categories with baseline products;
the source audit does not replace that comparison.

### Reproduce the explicit-method collision audit

This is read-only source analysis, not a test or compile. Expected output is
`2101 2101`, then `{}` and `{}`. The lexer masks comments/literals while retaining
offsets, checks implementation brace depth and distinguishes bodies from
declarations. It does not count protocol/interface/property declarations.

```python
import collections, re, subprocess

base = "14aa30b"
paths = subprocess.check_output(
    ["git", "ls-tree", "-r", "--name-only", base, "native"], text=True
).splitlines()
methods = collections.defaultdict(list)
for path in paths:
    if not path.endswith(".m"):
        continue
    raw = subprocess.check_output(["git", "show", base + ":" + path], text=True)
    source = re.sub(
        r'//[^\n]*|/\*[\s\S]*?\*/|@?"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
        lambda match: re.sub(r"[^\n]", " ", match[0]), raw,
    )
    for impl in re.finditer(
        r"@implementation\s+(\w+)(?:\s*\(\s*(\w*)\s*\))?([\s\S]*?)@end", source
    ):
        body = impl[3]
        for match in re.finditer(r"(?m)^[ \t]*([+-])\s*\(", body):
            prefix = body[:match.start()]
            if prefix.count("{") != prefix.count("}"):
                continue
            index, depth = match.end(), 1
            while depth and index < len(body):
                if body[index] == "(":
                    depth += 1
                elif body[index] == ")":
                    depth -= 1
                index += 1
            end = re.search(r"[;{]", body[index:])
            assert end
            if end[0] != "{":
                continue
            signature = body[index:index + end.start()]
            labels = re.findall(r"\b(\w+)\s*:", signature)
            name = re.match(r"\s*(\w+)", signature)
            assert labels or name, (path, signature)
            selector = "".join(label + ":" for label in labels) if labels else name[1]
            line = raw.count("\n", 0, impl.start(3) + match.start()) + 1
            methods[impl[1], match[1], selector].append((path, line))
print(sum(map(len, methods.values())), len(methods))
print({key: sites for key, sites in methods.items() if len(sites) > 1})
print({key: sites for key, sites in methods.items() if key[1:] == ("+", "load")})
```

## Deferred test build migration

Nothing in `tests/` is changed here. Six preceding refactors already invalidated
several test interfaces and slice markers; those are pre-existing migration
work, not evidence against archives. Distinguish direct production source lists,
textual `.m` inclusion with substituted boundaries, and fixture-only programs.
Force-loading an archive beside a fixture defining the same production class is
unsafe: replace the fake receiver or redesign the seam first. Force-load the
module under test; resolve dependency archives normally, not by blindly
force-loading every production module.

### Every e2e script with a native compilation command

This exhaustive baseline inventory includes fixture-only commands and compiler
wrappers, not just production source lists. Line numbers identify compiler
commands; their source lists continue on following lines in those scripts.

| Script (under `tests/e2e/`) | Native compiler command lines |
| --- | --- |
| `background-tiff.sh` | 12 |
| `capture-configuration.sh` | 9 |
| `compositor-dnd.sh` | 33, 35 |
| `compositor-lifetime.sh` | 10, 12 |
| `controller-hit.sh` | 11 |
| `family-geometry.sh` | 23 |
| `ipc-limits.sh` | 12 |
| `live-guest-lib.sh` | 57 |
| `mac-wallpaper-refresh.sh` | 9 |
| `native-chrome-input.sh` | 20 |
| `native-daemon.sh` | 15, 18, 32 |
| `native-decorations.sh` | 12 |
| `native-display-space-cache.sh` | 10 |
| `native-drag-drop.sh` | 93 |
| `native-family-recovery.sh` | 10 |
| `native-focus.sh` | 12, 14, 16 |
| `native-frame-restore.sh` | 7 |
| `native-input-policy.sh` | 11 |
| `native-launcher.sh` | 43 |
| `native-placement-validation.sh` | 10 |
| `native-presenter-readiness.sh` | 10, 15 |
| `native-resize-presentation.sh` | 16 |
| `native-view-transfer.sh` | 10 |
| `package-dmg.sh` | 21 |
| `physical-resize-edge.py` | 317 |
| `privileged-regression.sh` | 15 |
| `root-capture-mailbox.sh` | 89, 94 |
| `scoped-resize-drag.sh` | 84 |
| `scoped-sizing.sh` | 68 |
| `scoped-windows.sh` | 75 |
| `setup-assistant.sh` | 19 |
| `snapshot-mirror.sh` | 12 |
| `system-takeover.sh` | 11 |
| `window-discovery.sh` | 10 |
| `window-events.sh` | 10, 14 |

The `live-guest-lib.sh:55–58` compiler wrapper has additional manual source lists
at these call sites:

| Script | `live_guest_build` calls |
| --- | --- |
| `capture-stale-frame.sh` | 16, 17 |
| `native-frame-cap.sh` | 17, 19 |
| `native-snapshot-race.sh` | 17, 19 |
| `zero-screen-keys.sh` | 15, 16 |

`native-frame-cap.sh` and `native-snapshot-race.sh` also build an instrumented
fixture payload on continuation lines. Preserve that deliberate configuration.
`app-icon.sh` uses `actool`, not a native source compiler. Scripts delegating only
to `build-app.sh`/`build-privileged.sh` have no independent compiler list.

### Private-header references in tests

Every baseline test file mentioning one of the 40 moved header names is listed.
Bare-name imports keep resolving through legacy `native_includes` and
`helper_includes`, derived from the manifest with `Private/` search paths.
Physical path reads do not.

| Location | Header/reference | Migration effect |
| --- | --- | --- |
| `tests/e2e/native-drag-drop-driver.py:69` | `DWWindowServerFamily.h` | Documentation-only path/name. |
| `tests/e2e/root-capture-mailbox.sh:22` | `Desktop+Private.h` | Filesystem read breaks; use `native/app/Desktop/Private/Desktop+Private.h`. |
| `tests/native/app/Canvas/DWCanvasRendererTests.m:4` | `IFCompositor.h` | Bare import: retained via Private search path. |
| `tests/native/app/Canvas/IFBGTiffSourceTests.m:13` | `IFBGTiffSource.h` | Bare import: retained via Private search path. |
| `tests/native/app/Canvas/IFCompositorRendererTests.m:7` | `IFCompositor.h` | Bare import: retained via Private search path. |
| `tests/native/app/Desktop/DWControllerHitTests.m:6` | `DWControllerHit.h` | Bare import: retained via Private search path. |
| `tests/native/app/Desktop/DWRootCaptureMailboxTests.m:2` | `Desktop+Private.h` | Documentation-only path/name. |
| `tests/native/app/Desktop/DWSnapshotMirrorTests.m:5` | `DWSnapshotMirror.h` | Bare import: retained via Private search path. |
| `tests/native/app/Desktop/DesktopCapturedInputTests.m:2` | `Desktop+Private.h` | Documentation-only path/name. |
| `tests/native/app/Desktop/DesktopNativeChromeTests.m:8` | `DWControllerHit.h` | Bare import: retained via Private search path. |
| `tests/native/app/Input/DWNativeInputTests.m:14` | `DWNativeToolbarExtent.h` | Bare import: retained via Private search path. |
| `tests/native/app/Input/DWNativeInputTests.m:180` | `DWNativeToolbarExtent.h` | Documentation-only path/name. |
| `tests/native/app/System/DWSetupAssistantFixture.m:8` | `DWSetupButton.h` | Bare import: retained via Private search path. |

Only `tests/e2e/root-capture-mailbox.sh:22` executes a path-based read of a moved
private header (`app / "Desktop+Private.h"`). Other full-path references above
are comments. This does not imply bare-import tests compile after earlier
interface refactors.

### Four slicing scripts: concrete interface assessment

| Script | Existing public archive interface | Why migration is not just a linker edit |
| --- | --- | --- |
| `family-geometry.sh` | `DWCanvasRenderer.h`: readonly `hasGeometryTransitions` and `hasFamilyGeometryTransitions`. | `DWCanvasRendererTests.m` defines fake `DWCanvasOutput`, `GeometryRenderer`, `GeometryFrame`, `GeometryElement`, then compiles sliced methods into its fake renderer. There is no public injection interface for the fabricated renderer states/frame lifecycle. Linking Canvas exposes queries but does not feed these test states. Remove conflicting production class substitutes and exercise the real renderer, or deliberately introduce a separate state-query seam later. Headless isolation is not automatically preserved. |
| `native-chrome-input.sh` | `DWPressAdmission.h`: `initWithDesktop:scene:native:`, `consume:event:stage:`, `mouseDown:view:`, `prepareDrag:at:view:`; protocols `DWPressNativeLookup`, `DWPressSceneLookup`, `DWPressController`. | Its slices target `DWNativeChromeFrameMatches` and `earlyNativeTitle:` in `Desktop+NativeTitles.m`; admission now owns the consumer and the old marker is stale. `DesktopNativeChromeTests.m` includes `DWNativeInput.m`, defines fake `LiveSource`/other production receivers and returns dictionary controller responses. Typed scenes/replies and admission adapters must replace them. Static chrome predicates have no exported pure-function ABI; exercise acceptance through admission rather than renaming a slice. |
| `native-resize-presentation.sh` | `DWNativeResizePresentation.h`: `initWithPresenter:capture:`, `requiresBridgeForTransaction:`, `prepareEffect:ready:`, `allowsEffect:`, `update`, `cancel`. `DWSizeTransition.h`: `initWithHost:driver:capture:` with `DWSizeTransitionHost`, `consume:`/`consumeSize:`. | Presenter/coordinator scenarios can link CompositorMode/Navigation with injected interfaces after replacing dictionary fixtures with typed `DWResizeTransaction`/`DWSizeEffect`. But static `DWResizePresentationNativeBounds` moved from `Desktop+Navigation.m` to `Navigation/DWSizeTransition.m:119`. Three direct predicate assertions have no exported equivalent. Exercise transition-host capture arguments or deliberately add a seam later; do not claim force-loading exposes a static function. |
| `root-capture-mailbox.sh` | `DWRootCaptureMailbox.h`: `initWithSource:stream:`, `queue`, `currentImageAvailable`, `cancel`, inline `DWRootCaptureCrop`; `LiveSource.h`: `acceptCapturedSample:stream:received:forceInstall:`, `installPixels:`/`installPixels:contentRect:`. Captured press/Fill scenarios can use admission/size-transition entries above. | It slices mailbox/source internals, static transition image-geometry helpers, private captured-input predicates, DesktopView forwarding, title-click and Fill methods. It reads deleted `Desktop+Fill.m` before slicing, plus moved `Desktop+Private.h`. `DWRootCaptureMailboxTests.m` substitutes sample storage/install/dispatch and includes generated interface/implementation fragments; `DesktopCapturedInputTests.m` substitutes multiple receivers. Real mailbox APIs do not inject every substitution. `DWNativeTransitionCapture +captureIdentity:nativeBounds:screenRect:validate:completion:` performs native capture, not the static pure geometry predicates. Split scenarios by actual boundary and explicitly design missing native-free seams in the later test phase. |

A public header is an available entry point, not proof that a fixture's fake
state and no-native-side-effect guarantees transfer to it.

## Production entry points and Rust-header ownership

At baseline, `scripts/check.sh:97` delegates app compilation to
`build-app.sh`; `scripts/build-release.sh:39` delegates with release
version/build/repository environment. Neither duplicates a native compiler list.
Native source compiler lists in production shell scripts occur only in
`build-app.sh` and `build-privileged.sh`. `install-app.sh:25` and
`start-native-desktop.sh:50` delegate too. Candidate 7 moves lists into the
manifest/driver without changing the external build-app contract.

All baseline direct `driftwm_desktop.h` imports/includes:

| Baseline location | Module | Purpose |
| --- | --- | --- |
| `native/app/Controller/DWController+Private.h:4` | Controller | Controller transport ABI. |
| `native/app/Controller/DWSnapshotMirror.h:4` | Controller | Private mirror ABI; moves to `Controller/Private/`. |
| `native/app/Controller/DWSceneWriter.h:3` | Controller | Public opaque-pointer API unnecessarily pulled in Rust definitions; transitively reached Desktop. |
| `native/app/System/DWIPCServer.m:27` | System | IPC Rust boundary. |

Migrated state: `DWSceneWriter.h` keeps an opaque `struct DriftDesktop` typedef
instead of the Rust include, which moves to `DWSceneWriter.m`. `app/main.m`
imports `driftwm_desktop.h` directly rather than copying C function prototypes.
Only Controller, System and the app entry receive `-Icrates/desktop/src` in
production compile inputs. The entry has explicit include directories in the
manifest. Legacy flat test include variables retain their broad meaning.

## Verification limits

Read-only Python source scans and `git show 14aa30b:PATH` supplied the graph,
selector audit and test inventories. Collision scan output was `2101 2101`,
duplicates `{}`, `+load` `{}` (exit 0). Re-running the same parser on the parent's
edited worktree also returned `2101 2101`, `{}`, `{}`. A separate read-only check
resolved all 145 cyclic-import locations against the baseline and confirmed the
exact quoted header at each source line (exit 0). The documentation's embedded
Python parsed and executed successfully; its Markdown fences are balanced.
No compiler, test runner, app, event tap or native capture was invoked. Binary
symbol/class/category comparison and guest compile evidence belong to the parent
and are not claimed here.
