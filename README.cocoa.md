# MicroEmacs macOS Cocoa Port

A native macOS GUI for JASSPA MicroEmacs built on **AppKit** and **CoreText**.

The port is the AppKit counterpart of the Xlib back-end in `unixterm.c`. It
presents exactly the same interface to the editor core — the `meFrameXTerm*`
drawing entry points, the character cell metrics in `mecm` and the `XTERM*`
start-up/colour hooks — so `display.c`, `osd.c` and the rest of the editor
render through it unchanged.

## Files

| File | Purpose |
|------|---------|
| `src/cocoaterm.m` | The whole window back-end: window/frame management, CoreText rendering, event pump, fonts, colours, cursor, menus, clipboard, drag and drop |
| `src/CocoaBundleInfo.plist` | `Info.plist` for the application bundle |
| `src/me.icns` | Application icon |
| `src/eterm.h` | `_COCOA` section: `meCellMetrics`, the pixel/cell macros and the back-end prototypes |
| `src/emain.h` | Selects `_COCOA` instead of `_XTERM` on Darwin, defines `_ME_GUI` |
| `src/unixterm.c` | Shared UNIX layer (paths, signals, timers, termcap console); gained a Cocoa branch in `TTstart`, `TTahead` and `waitForEvent` |

## Building

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
open build/src/me.app
```

The result is an application bundle at `build/src/me.app` with the standard
macro library installed in `Contents/Resources/macros`, so a double-clicked
application finds its macros without any environment setup.

To build the terminal-only version (no AppKit, no bundle):

```bash
cmake -S . -B build-console -DENABLE_GUI=OFF
cmake --build build-console          # -> build-console/src/me
```

A GUI build still contains the termcap console; `me -n` runs in the terminal.

## How it works

### Platform selection

macOS is a FreeBSD derivative, so `emain.h` picks up the FreeBSD feature set and
then swaps the window system:

```c
#ifdef _DARWIN
#undef  _XTERM          /* Not Xlib ... */
#define _COCOA  1       /* ... AppKit   */
#endif
```

Code that is genuinely shared between the two bit-mapped back-ends (the
rendering loops in `display.c`, the OSD repaint in `osd.c`) is guarded with
`_ME_GUI`, which is defined when either `_XTERM` or `_COCOA` is in use.

### Rendering

The editor core draws immediately, straight at the window, which is a model
AppKit does not allow — real drawing may only happen inside `-drawRect:`. The
back-end bridges the two with an offscreen canvas:

```
display.c / osd.c
      │  meFrameXTermSetScheme / DrawString / DrawSpecialChar / Draw
      ▼
CGBitmapContext  (one per frame, sized to whole character cells,
      │           scaled for the display's backing factor)
      ▼  meCocoaFlush()  ->  setNeedsDisplayInRect: + displayIfNeeded
MEView -drawRect:  blits the damaged part of the canvas
      ▼
NSWindow
```

The canvas is set up with a top-left origin and y running down the screen so
that the editor's row/column arithmetic (`rowToClient`, `colToClient`) needs no
adjustment. Every primitive accumulates a dirty rectangle, so a flush only
composites the pixels that actually changed.

Text is drawn with `CTFontDrawGlyphs`, one glyph per character cell at a fixed
pitch, so the grid stays exact whatever the font's advance is. Each font style
keeps a 256-entry character-to-glyph table, built once, so drawing a run never
goes near the layout engine. The graphics characters that MicroEmacs uses for
scroll bars, line drawing and check boxes (`0x01`-`0x1f`) are stroked and filled
directly, matching the Xlib renderer shape for shape.

### Event loop

MicroEmacs owns the main loop (`main()` runs `doOneKey()` forever), so
`-[NSApplication run]` is never called. Instead the AppKit queue is pumped
explicitly:

* `TTahead()` → `meCocoaEventHandler()` drains the queue without blocking.
* `waitForEvent()` → `meCocoaWaitEvent(msec)` sleeps in `nextEventMatchingMask:`
  until an event arrives or the next editor timer is due. The editor's timers
  are driven by `SIGALRM`, which does not break an AppKit wait, so the sleep is
  always bounded by the head of the timer list.
* Incremental pipes are plain file descriptors rather than run-loop sources, so
  they are polled with a zero-timeout `select()` before AppKit is given the
  chance to sleep.

Keys, mouse events, resizes, focus changes and window closes are delivered
through the normal responder chain (`MEView`/`MEWindow`) and converted into the
editor's key codes.

### Menus

The application menu bar drives the editor by pushing the key sequence that
`execute-named-command` understands, so every command runs from the editor's own
command loop rather than from inside an AppKit callback:

```c
addKeyToBuffer(ME_SPECIAL|SKEY_x_command) ;
/* ... the command name ... */
addKeyToBuffer(ME_SPECIAL|SKEY_return) ;
```

| Menu | Items |
|------|-------|
| MicroEmacs | About, Describe Bindings, List Commands/Variables, Hide, Quit (⌘Q → `save-buffers-exit-emacs` semantics) |
| File | Open ⌘O, Open Read Only, Insert File, Save ⌘S, Save As, Save All, Close Buffer ⌘W, List Buffers, Print ⌘P |
| Edit | Undo ⌘Z, Cut ⌘X, Copy ⌘C, Paste ⌘V, Select All ⌘A, Find ⌘F, Find Next ⌘G, Find Previous, Incremental Search, Replace, Go to Line ⌘L |
| View | Bigger/Smaller Font ⌘+/⌘-, Actual Size ⌘0, Change Font, Split Window ⌘2, Delete Window ⌘1, Next Window, Redraw |
| Window | Minimize ⌘M, Zoom, Enter Full Screen ⌃⌘F, New/Next/Delete Frame |
| Help | Help ⌘?, Describe Key, Command Apropos |

The editor's own OSD menu bar (File/Edit/Search/View/…) is unaffected and still
works from the keyboard.

### Frames, fonts, colour and the rest

* **Frames** — each editor frame owns one `NSWindow`, so `create-frame`,
  `next-frame` and `delete-frame` behave as they do under X11. Closing a window
  with the red button deletes that frame, or quits if it is the last one.
* **Resizing** — the content resize increment is the character cell, so dragging
  a window snaps to whole rows and columns; `windowDidResize:` reflows the
  editor the same way the X11 `ConfigureNotify` handler does.
* **Fonts** — a monospaced face (Menlo by default, then SF Mono, Monaco, Courier
  New, then the user's fixed-pitch font). Bold and italic variants are derived
  from the base face on demand; underline is stroked after the glyphs.
  `change-font` takes `Family` or `Family-Size`, e.g. `Menlo-14`.
* **Retina** — the canvas is allocated at the window's backing scale factor and
  rebuilt when the window moves to a display with a different pixel density.
* **Cursor** — a solid block in the cursor colour when the frame has focus, an
  outline when it does not; blinking is driven by the editor's existing timer.
* **Clipboard** — `TTsetClipboard` claims the general pasteboard with a lazy
  provider, exactly as the Win32 port uses delayed rendering, so the kill buffer
  is only flattened when another application asks for it. `TTgetClipboard`
  detects that someone else has taken ownership through the pasteboard change
  count, and normalises CRLF on the way in.
* **Drag and drop** — file URLs dropped on a window, and files opened through
  the Finder, are queued on the editor's existing `dadHead` list.
* **Mouse** — clicks, drags, movement and the scroll wheel are mapped onto the
  editor's mouse keys. Trackpad scrolling accumulates fractional deltas so one
  gesture does not flood the key buffer.
* **`shell`** — with no terminal attached to the window, `shell` opens
  Terminal.app on the current directory, which is the macOS equivalent of the
  Xlib back-end firing off an `xterm`.

## Differences from the other back-ends

| Feature | Win32 (`winterm.c`) | Xlib (`unixterm.c`) | Cocoa (`cocoaterm.m`) |
|---------|---------------------|---------------------|------------------------|
| Window | `CreateWindow` | `XCreateSimpleWindow` | `NSWindow` |
| Event loop | `GetMessage` | `XNextEvent` | `nextEventMatchingMask:` pumped from `TTahead()` |
| Drawing | GDI, direct | Xlib, direct | CoreGraphics bitmap canvas blitted by `NSView` |
| Text | `TextOut` | `XDrawImageString` | `CTFontDrawGlyphs`, one glyph per cell |
| Fonts | `CreateFontIndirect` | XLFD name mangling | `NSFont` + symbolic traits |
| Colour | `colTable` = `COLORREF` | `colTable` = X pixel | `colTable` = packed `0x00rrggbb` |
| Clipboard | Delayed rendering | Selection protocol | `NSPasteboard` lazy provider |
| Menus | None (OSD only) | None (OSD only) | Native `NSMenu` bar plus OSD |
| Multiple frames | Yes | Yes | Yes |

## Known limitations

* The editor core is byte oriented — one buffer position is one byte, and
  the renderer draws one glyph per byte. Latin-1 text round-trips exactly.
  A character typed outside that range (Cyrillic, CJK, emoji, …) is encoded
  as UTF-8 and its bytes are inserted, so the text is preserved and saves
  back out as correct UTF-8, but until the renderer understands multi-byte
  sequences each byte still occupies its own cell on screen rather than
  combining into the one character it represents. There is no input method
  / dead key composition (the Xlib back-end has the same limit, via
  `XLookupString` without XIM).
* Command (⌘) is reserved for the macOS menu bar and is not available as an
  editor modifier. Control maps to `ME_CONTROL` and Option to `ME_ALT`.
* The bundle is unsigned; Gatekeeper will need the usual right-click → Open the
  first time it is run from somewhere other than the build tree.
* Printing still goes through `print.c`; there is no `NSPrintOperation`
  integration.

## License

Same as the rest of MicroEmacs — GPL v2 or later.
