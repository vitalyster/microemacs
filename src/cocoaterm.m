/* -*- objc -*-
 *
 * JASSPA MicroEmacs - www.jasspa.com
 * cocoaterm.m - macOS AppKit (Cocoa) window support routines.
 *
 * Copyright (C) 1994-2009 JASSPA (www.jasspa.com)
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation; either version 2 of the License, or (at your option)
 * any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
 * more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 675 Mass Ave, Cambridge, MA 02139, USA.
 */
/*
 * Synopsis:    macOS AppKit window support routines.
 * Description:
 *     The macOS window back-end. This is the AppKit counterpart of the Xlib
 *     code in unixterm.c and presents exactly the same interface to the
 *     editor core (the meFrameXTerm* entry points, the cell metrics in 'mecm'
 *     and the XTERM* start-up/colour hooks), so display.c and osd.c render
 *     through it unchanged.
 *
 *     Each editor frame owns one NSWindow. Rendering is immediate, exactly as
 *     it is under X11: the drawing primitives paint into an offscreen
 *     CGBitmapContext (the canvas) and the NSView blits the dirty part of the
 *     canvas when the display is flushed. This keeps the "draw straight at
 *     the window" model that the editor core assumes whilst still satisfying
 *     AppKit, which only allows real drawing from within -drawRect:.
 *
 *     The editor owns the main loop (see main()), so the AppKit event queue is
 *     pumped explicitly from TTahead()/waitForEvent() rather than by calling
 *     -[NSApplication run].
 */

#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>

#include "emain.h"
#include "evers.h"                      /* Version information */
#include "efunc.h"
#include "eskeys.h"

#ifdef _COCOA

/**************************************************************************
* Local types                                                             *
**************************************************************************/

@class MEView ;
@class MEWindow ;

/* A single font style. The glyph table maps the editors 8-bit characters
 * (interpreted as ISO-8859-1, as the X11 back-end does) onto glyphs so that
 * drawing a run of text never has to go near the layout engine. */
typedef struct
{
    CTFontRef font ;                    /* The CoreText font, NULL if unset */
    CGGlyph   glyph[256] ;              /* Character => glyph translation */
    CGFloat   xoff ;                    /* Offset to centre in the cell */
    int       loaded ;                  /* Glyph table has been built */
} meCocoaFont ;

/* Per frame terminal data - the counterpart of the X11 meFrameData */
struct meCocoaFrameData
{
    MEWindow    *window ;               /* The frames window */
    MEView      *view ;                 /* The canvas view within it */
    CGContextRef ctx ;                  /* Offscreen canvas */
    int          pwidth ;               /* Canvas width in points */
    int          pdepth ;               /* Canvas depth in points */
    CGFloat      originX ;              /* Canvas offset within the view - */
    CGFloat      originY ;              /* - keeps clear of the safe area  */
    CGFloat      scale ;                /* Backing store scale factor */
    meUByte      fcol ;                 /* Current foreground colour */
    meUByte      bcol ;                 /* Current background colour */
    meUByte      cgcol ;                /* Colour loaded into the context */
    meUByte      font ;                 /* Current font style */
    meCocoaFont *fontCur ;              /* Current font */
    CGRect       dirty ;                /* Region awaiting a blit */
    int          hasDirty ;             /* Region is valid */
} ;

/**************************************************************************
* Local data                                                              *
**************************************************************************/

meCellMetrics mecm ;                    /* The character cell metrics */

char *meName = ME_FULLNAME ;            /* Name used in the window title */

static meCocoaFont meFontTbl[meFONT_MAX] ;
static NSString   *meFontFamily = nil ; /* Family of the current font */
static meFrameData *firstFrameData = NULL ;
static int   meWindowCount = 0 ;        /* Number of windows created */
static int   disableResize = 0 ;        /* Flag to disable screen resize */
static meUByte meCurCursor = 0xff ;     /* Current mouse cursor shape */
static NSInteger meClipChangeCount = -1 ;   /* Pasteboard generation we own */

#define meCOCOA_FONT_MIN   6            /* Smallest font point size */
#define meCOCOA_FONT_MAX   72           /* Largest font point size */
#define meCOCOA_FONT_DEF   12           /* Default font point size */

/* Unpack a colTable entry, they are stored as 0x00rrggbb */
#define meColRed(c)    ((CGFloat) (((c) >> 16) & 0xff) / 255.0)
#define meColGreen(c)  ((CGFloat) (((c) >>  8) & 0xff) / 255.0)
#define meColBlue(c)   ((CGFloat) ( (c)        & 0xff) / 255.0)

static void meCocoaFrameCanvasCreate(meFrame *frame) ;
static void meCocoaFrameCanvasFree(meFrameData *fd) ;
static int  meCocoaSetFont(NSString *family, int size) ;

static NSEdgeInsets
meCocoaSafeAreaInsets(NSView *view)
{
    if(@available(macOS 26.0, *))
    {
        NSViewLayoutRegion *region =
            [NSViewLayoutRegion safeAreaLayoutRegionWithCornerAdaptation:
                                     NSViewLayoutRegionAdaptivityAxisVertical] ;
        return [view edgeInsetsForLayoutRegion:region] ;
    }
    return [view safeAreaInsets] ;
}

static NSSize
meCocoaInsetSize(NSSize sz, NSEdgeInsets insets)
{
    sz.width  -= insets.left + insets.right ;
    sz.height -= insets.top + insets.bottom ;
    return sz ;
}

static NSSize
meCocoaOutsetSize(NSSize sz, NSEdgeInsets insets)
{
    sz.width  += insets.left + insets.right ;
    sz.height += insets.top + insets.bottom ;
    return sz ;
}

static void meCocoaFontChanged(void) ;
static void meCocoaBuildMenu(void) ;
static void meCocoaKeyEvent(NSEvent *ev) ;
static void meCocoaMouseEvent(meFrame *frame, NSEvent *ev, int type) ;
static void meCocoaFrameGainFocus(meFrame *frame) ;
static void meCocoaFrameKillFocus(meFrame *frame) ;

/**************************************************************************
* Canvas view                                                             *
**************************************************************************/

@interface MEView : NSView
{
    meFrame *meFrameRef ;
    NSCursor *meCursor ;
}
- (void) meSetFrame:(meFrame *)frame ;
- (void) meSetCursor:(NSCursor *)cursor ;
@end

@implementation MEView

- (void) meSetFrame:(meFrame *)frame
{
    meFrameRef = frame ;
}

- (void) meSetCursor:(NSCursor *)cursor
{
    if(meCursor != cursor)
    {
        [meCursor release] ;
        meCursor = [cursor retain] ;
    }
    [[self window] invalidateCursorRectsForView:self] ;
}

/* Use a top-left origin so that the view, the canvas and the editors row and
 * column coordinates all agree */
- (void) dealloc
{
    [meCursor release] ;
    [super dealloc] ;
}

- (BOOL) isFlipped                  { return YES ; }
- (BOOL) acceptsFirstResponder      { return YES ; }
- (BOOL) canBecomeKeyView           { return YES ; }
- (BOOL) isOpaque                   { return YES ; }

- (void) resetCursorRects
{
    if(meCursor != nil)
    {
        NSEdgeInsets insets = meCocoaSafeAreaInsets(self) ;
        NSRect r = [self bounds] ;

        r.origin.x += insets.left ;
        r.origin.y += insets.top ;
        r.size.width -= insets.left + insets.right ;
        r.size.height -= insets.top + insets.bottom ;
        [self addCursorRect:r cursor:meCursor] ;
    }
}

- (void) drawRect:(NSRect)rect
{
    meFrameData *fd ;
    CGContextRef cg ;
    CGImageRef img ;

    if((meFrameRef == NULL) ||
       ((fd = (meFrameData *) meFrameRef->termData) == NULL) || (fd->ctx == NULL))
        return ;

    cg = [[NSGraphicsContext currentContext] CGContext] ;

    /* Blit the canvas, offset clear of the safe area (the camera housing on
     * a notched display in full screen; zero everywhere else). The context
     * is clipped to the invalid region so only the damaged pixels are
     * actually composited. */
    if((img = CGBitmapContextCreateImage(fd->ctx)) != NULL)
    {
        CGContextSaveGState(cg) ;
        CGContextTranslateCTM(cg,fd->originX,fd->originY+fd->pdepth) ;
        CGContextScaleCTM(cg,1.0,-1.0) ;
        CGContextSetInterpolationQuality(cg,kCGInterpolationNone) ;
        CGContextDrawImage(cg,CGRectMake(0.0,0.0,fd->pwidth,fd->pdepth),img) ;
        CGContextRestoreGState(cg) ;
        CGImageRelease(img) ;
    }

    /* The window may be a little larger than the character grid - because of
     * slack below the last whole cell, or a safe area inset - fill the
     * exposed border with the global background colour so it does not
     * flicker */
    {
        NSSize bounds = [self bounds].size ;

        if((bounds.width > fd->pwidth+fd->originX) ||
           (bounds.height > fd->pdepth+fd->originY) ||
           (fd->originX > 0.0) || (fd->originY > 0.0))
        {
            meUInt col = (noColors > 0) ?
                colTable[meStyleGetBColor(meSchemeGetStyle(globScheme))]:0 ;
            CGContextSetRGBFillColor(cg,meColRed(col),meColGreen(col),meColBlue(col),1.0) ;
            CGContextFillRect(cg,CGRectMake(0.0,0.0,bounds.width,fd->originY)) ;
            CGContextFillRect(cg,CGRectMake(0.0,fd->originY+fd->pdepth,
                                            bounds.width,
                                            bounds.height-(fd->originY+fd->pdepth))) ;
            CGContextFillRect(cg,CGRectMake(0.0,fd->originY,
                                            fd->originX,fd->pdepth)) ;
            CGContextFillRect(cg,CGRectMake(fd->originX+fd->pwidth,fd->originY,
                                            bounds.width-(fd->originX+fd->pwidth),
                                            fd->pdepth)) ;
        }
    }
}

- (void) safeAreaInsetsDidChange
{
    /* The window moved in or out of full screen on a notched display (or
     * similar) - rebuild the canvas clear of the new safe area */
    if(meFrameRef != NULL)
    {
        meCocoaFrameCanvasCreate(meFrameRef) ;
        sgarbf = meTRUE ;
        [self setNeedsDisplay:YES] ;
    }
}

/**********************************************************************
 * Keyboard                                                            *
 **********************************************************************/

- (void) keyDown:(NSEvent *)ev
{
    meCocoaKeyEvent(ev) ;
}

- (void) flagsChanged:(NSEvent *)ev
{
    /* The editor generates its own shift/control pick and drop events so the
     * modifier transitions are of no interest, however the caps-lock state is
     * reported if the user has bound it. */
    static BOOL capsLock = NO ;
    BOOL nowLocked = (([ev modifierFlags] & NSEventModifierFlagCapsLock) != 0) ;
    meUShort cc ;
    meUInt arg ;

    if(nowLocked == capsLock)
        return ;
    capsLock = nowLocked ;
    cc = ME_SPECIAL | SKEY_caps_lock ;
    if(decode_key(cc,&arg) != -1)
        addKeyToBuffer(cc) ;
}

/**********************************************************************
 * Mouse                                                               *
 **********************************************************************/
#if MEOPT_MOUSE
- (void) mouseDown:(NSEvent *)ev        { meCocoaMouseEvent(meFrameRef,ev,1) ; }
- (void) mouseUp:(NSEvent *)ev          { meCocoaMouseEvent(meFrameRef,ev,2) ; }
- (void) rightMouseDown:(NSEvent *)ev   { meCocoaMouseEvent(meFrameRef,ev,1) ; }
- (void) rightMouseUp:(NSEvent *)ev     { meCocoaMouseEvent(meFrameRef,ev,2) ; }
- (void) otherMouseDown:(NSEvent *)ev   { meCocoaMouseEvent(meFrameRef,ev,1) ; }
- (void) otherMouseUp:(NSEvent *)ev     { meCocoaMouseEvent(meFrameRef,ev,2) ; }
- (void) mouseDragged:(NSEvent *)ev     { meCocoaMouseEvent(meFrameRef,ev,0) ; }
- (void) rightMouseDragged:(NSEvent *)ev { meCocoaMouseEvent(meFrameRef,ev,0) ; }
- (void) otherMouseDragged:(NSEvent *)ev { meCocoaMouseEvent(meFrameRef,ev,0) ; }
- (void) mouseMoved:(NSEvent *)ev       { meCocoaMouseEvent(meFrameRef,ev,0) ; }
- (void) scrollWheel:(NSEvent *)ev      { meCocoaMouseEvent(meFrameRef,ev,3) ; }
#endif /* MEOPT_MOUSE */

/**********************************************************************
 * Drag and drop                                                       *
 **********************************************************************/
#ifdef _DRAGNDROP
- (NSDragOperation) draggingEntered:(id <NSDraggingInfo>)sender
{
    if([[[sender draggingPasteboard] types] containsObject:NSPasteboardTypeFileURL])
        return NSDragOperationCopy ;
    return NSDragOperationNone ;
}

- (BOOL) performDragOperation:(id <NSDraggingInfo>)sender
{
    NSPasteboard *pb = [sender draggingPasteboard] ;
    NSArray *urls ;
    NSPoint pt ;
    int added = 0 ;

    urls = [pb readObjectsForClasses:@[[NSURL class]]
                             options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}] ;
    if((urls == nil) || ([urls count] == 0) || (meFrameRef == NULL))
        return NO ;

    pt = [self convertPoint:[sender draggingLocation] fromView:nil] ;

    for(NSURL *url in urls)
    {
        struct s_DragAndDrop *dadp ;
        const char *path = [[url path] fileSystemRepresentation] ;
        size_t len ;

        if(path == NULL)
            continue ;
        len = strlen(path) ;
        if((dadp = (struct s_DragAndDrop *)
            meMalloc(sizeof(struct s_DragAndDrop) + len)) == NULL)
            break ;
        memcpy(dadp->fname,path,len+1) ;
        dadp->mouse_x = (meUShort) pt.x ;
        dadp->mouse_y = (meUShort) pt.y ;
        dadp->frame = meFrameRef ;
        dadp->next = dadHead ;
        dadHead = dadp ;
        added++ ;
    }
    if(added == 0)
        return NO ;

    /* Wake the editor up so that the list is processed */
    addKeyToBuffer(ME_SPECIAL|SKEY_redraw) ;
    return YES ;
}
#endif /* _DRAGNDROP */

@end

/**************************************************************************
* Frame window                                                            *
**************************************************************************/

@interface MEWindow : NSWindow <NSWindowDelegate>
{
    meFrame *meFrameRef ;
}
- (void) meSetFrame:(meFrame *)frame ;
@end

@implementation MEWindow

- (void) meSetFrame:(meFrame *)frame
{
    meFrameRef = frame ;
}

- (BOOL) canBecomeKeyWindow  { return YES ; }
- (BOOL) canBecomeMainWindow { return YES ; }

- (void) windowDidBecomeKey:(NSNotification *)note
{
    meCocoaFrameGainFocus(meFrameRef) ;
}

- (void) windowDidResignKey:(NSNotification *)note
{
    meCocoaFrameKillFocus(meFrameRef) ;
}

- (void) windowDidChangeBackingProperties:(NSNotification *)note
{
    /* Dragged onto a display with a different pixel density - the canvas has
     * to be rebuilt at the new resolution */
    if(meFrameRef != NULL)
    {
        meCocoaFrameCanvasCreate(meFrameRef) ;
        sgarbf = meTRUE ;
    }
}

- (void) windowDidResize:(NSNotification *)note
{
    meFrame *frame = meFrameRef ;
    meFrameData *fd ;
    NSSize sz ;
    int ww, hh, sizeSet ;

    if((frame == NULL) || ((fd = (meFrameData *) frame->termData) == NULL))
        return ;

    sz = meCocoaInsetSize([[self contentView] frame].size,
                          meCocoaSafeAreaInsets([self contentView])) ;
    ww = ((int) sz.width) / mecm.fwidth ;
    hh = ((int) sz.height) / mecm.fdepth ;
    if(ww < 10)
        ww = 10 ;
    if(hh < 4)
        hh = 4 ;

    /* Rebuild the canvas before the editor is told about the new size, the
     * drawing that follows must have somewhere legal to land */
    meCocoaFrameCanvasCreate(frame) ;

    /* As with the X11 back-end both dimensions are established before the
     * window is told about the change, otherwise the editor and the window
     * server beat against each other */
    disableResize = 1 ;
    sizeSet = 0 ;
    if(ww != frame->width)
    {
        meFrameChangeWidth(frame,ww) ;
        sizeSet = 1 ;
    }
    if(hh != (frame->depth+1))
    {
        meFrameChangeDepth(frame,hh) ;
        sizeSet = 1 ;
    }
    disableResize = 0 ;

    if(sizeSet && !screenUpdateDisabledCount)
        screenUpdate(meTRUE,2-sgarbf) ;
}

- (BOOL) windowShouldClose:(id)sender
{
    meFrame *frame = meFrameRef ;

    if(frame == NULL)
        return NO ;
#if MEOPT_MWFRAME
    if(meFrameDelete(frame,6) <= 0)
#endif
    {
        /* Use the normal command to save buffers and exit, if it does not
         * exit then carry on as normal. Must ensure we ask the user, not a
         * macro. */
        int savcle ;
        savcle = clexec ;
        clexec = meFALSE ;
        exitEmacs(1,3) ;
        clexec = savcle ;
    }
    /* If we are still here then the editor declined to quit */
    return NO ;
}

@end

/**************************************************************************
* Application delegate and menu actions                                   *
**************************************************************************/

/*
 * meCocoaPushCommand
 * Queue a named editor command for execution. The command is injected as the
 * key sequence that the "execute-named-command" binding understands, which
 * means the command runs from the editors own command loop rather than from
 * inside an AppKit callback.
 */
static void
meCocoaPushCommand(const char *name)
{
    addKeyToBuffer(ME_SPECIAL|SKEY_x_command) ;
    while(*name != '\0')
        addKeyToBuffer((meUShort) (meUByte) *name++) ;
    addKeyToBuffer(ME_SPECIAL|SKEY_return) ;
}

@interface MEApplicationDelegate : NSObject <NSApplicationDelegate, NSPasteboardTypeOwner>
- (void) meCommand:(id)sender ;
- (void) meFontBigger:(id)sender ;
- (void) meFontSmaller:(id)sender ;
- (void) meFontDefault:(id)sender ;
@end

static MEApplicationDelegate *meAppDelegate = nil ;

@implementation MEApplicationDelegate

/* All of the editor driven menu items come through here, the command name is
 * carried in the menu items represented object */
- (void) meCommand:(id)sender
{
    id obj = [sender representedObject] ;

    if([obj isKindOfClass:[NSArray class]])
    {
        for(NSString *cmd in (NSArray *) obj)
            meCocoaPushCommand([cmd UTF8String]) ;
    }
    else if([obj isKindOfClass:[NSString class]])
        meCocoaPushCommand([(NSString *) obj UTF8String]) ;
}

- (void) meFontBigger:(id)sender
{
    meCocoaSetFont(meFontFamily,mecm.fontSize+1) ;
    meCocoaFontChanged() ;
}

- (void) meFontSmaller:(id)sender
{
    meCocoaSetFont(meFontFamily,mecm.fontSize-1) ;
    meCocoaFontChanged() ;
}

- (void) meFontDefault:(id)sender
{
    meCocoaSetFont(meFontFamily,meCOCOA_FONT_DEF) ;
    meCocoaFontChanged() ;
}

- (NSApplicationTerminateReply) applicationShouldTerminate:(NSApplication *)app
{
    /* The Quit menu item and the Dock both land here. Hand the request to the
     * editor so that modified buffers are offered for saving - if the editor
     * agrees to exit it calls meExit() and never comes back. */
    int savcle ;
    savcle = clexec ;
    clexec = meFALSE ;
    exitEmacs(1,3) ;
    clexec = savcle ;
    return NSTerminateCancel ;
}

- (BOOL) applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
    return NO ;
}

#ifdef _DRAGNDROP
- (BOOL) application:(NSApplication *)app openFile:(NSString *)filename
{
    struct s_DragAndDrop *dadp ;
    const char *path = [filename fileSystemRepresentation] ;
    size_t len ;

    if((path == NULL) || (frameCur == NULL))
        return NO ;
    len = strlen(path) ;
    if((dadp = (struct s_DragAndDrop *)
        meMalloc(sizeof(struct s_DragAndDrop) + len)) == NULL)
        return NO ;
    memcpy(dadp->fname,path,len+1) ;
    dadp->mouse_x = 0 ;
    dadp->mouse_y = 0 ;
    dadp->frame = frameCur ;
    dadp->next = dadHead ;
    dadHead = dadp ;
    addKeyToBuffer(ME_SPECIAL|SKEY_redraw) ;
    return YES ;
}
#endif /* _DRAGNDROP */

#ifdef _CLIPBRD
/* Lazy clipboard rendering - the kill buffer is only flattened into the
 * pasteboard when another application actually asks for it */
- (void) pasteboard:(NSPasteboard *)pb provideDataForType:(NSPasteboardType)type
{
    meKillNode *killp ;
    NSMutableData *data ;

    if(![type isEqualToString:NSPasteboardTypeString] || (klhead == NULL))
        return ;

    data = [NSMutableData data] ;
    killp = klhead->kill ;
    while(killp != NULL)
    {
        [data appendBytes:killp->data length:meStrlen(killp->data)] ;
        killp = killp->next ;
    }
    if((meSystemCfg & meSYSTEM_NOEMPTYANK) && ([data length] == 0))
        [data appendBytes:" " length:1] ;

    [pb setString:[[[NSString alloc] initWithData:data
                                        encoding:NSUTF8StringEncoding] autorelease]
          forType:NSPasteboardTypeString] ;
}
#endif /* _CLIPBRD */

@end

/**************************************************************************
* Menu construction                                                       *
**************************************************************************/

static NSMenuItem *
meCocoaMenuAdd(NSMenu *menu, NSString *title, NSString *key,
               NSEventModifierFlags mods, const char *command)
{
    NSMenuItem *item ;

    item = [menu addItemWithTitle:title
                           action:@selector(meCommand:)
                    keyEquivalent:(key != nil) ? key:@""] ;
    if(key != nil)
        [item setKeyEquivalentModifierMask:mods] ;
    [item setTarget:meAppDelegate] ;
    [item setRepresentedObject:[NSString stringWithUTF8String:command]] ;
    return item ;
}

static void
meCocoaBuildMenu(void)
{
    NSMenu *bar, *menu ;
    NSMenuItem *item ;
    NSString *appName = [NSString stringWithUTF8String:ME_FULLNAME] ;

    bar = [[NSMenu alloc] init] ;

    /* ---- Application menu ------------------------------------------- */
    item = [bar addItemWithTitle:@"" action:NULL keyEquivalent:@""] ;
    menu = [[NSMenu alloc] init] ;
    [item setSubmenu:menu] ;
    [menu addItemWithTitle:[@"About " stringByAppendingString:appName]
                    action:@selector(orderFrontStandardAboutPanel:)
             keyEquivalent:@""] ;
    [menu addItem:[NSMenuItem separatorItem]] ;
    meCocoaMenuAdd(menu,@"Describe Bindings",nil,0,"describe-bindings") ;
    meCocoaMenuAdd(menu,@"List Commands",nil,0,"list-commands") ;
    meCocoaMenuAdd(menu,@"List Variables",nil,0,"list-variables") ;
    [menu addItem:[NSMenuItem separatorItem]] ;
    [menu addItemWithTitle:[@"Hide " stringByAppendingString:appName]
                    action:@selector(hide:) keyEquivalent:@"h"] ;
    item = [menu addItemWithTitle:@"Hide Others"
                           action:@selector(hideOtherApplications:)
                    keyEquivalent:@"h"] ;
    [item setKeyEquivalentModifierMask:NSEventModifierFlagCommand|NSEventModifierFlagOption] ;
    [menu addItemWithTitle:@"Show All"
                    action:@selector(unhideAllApplications:) keyEquivalent:@""] ;
    [menu addItem:[NSMenuItem separatorItem]] ;
    [menu addItemWithTitle:[@"Quit " stringByAppendingString:appName]
                    action:@selector(terminate:) keyEquivalent:@"q"] ;

    /* ---- File menu -------------------------------------------------- */
    item = [bar addItemWithTitle:@"File" action:NULL keyEquivalent:@""] ;
    menu = [[NSMenu alloc] initWithTitle:@"File"] ;
    [item setSubmenu:menu] ;
    meCocoaMenuAdd(menu,@"Open...",@"o",NSEventModifierFlagCommand,"find-file") ;
    meCocoaMenuAdd(menu,@"Open Read Only...",nil,0,"view-file") ;
    meCocoaMenuAdd(menu,@"Insert File...",nil,0,"insert-file") ;
    [menu addItem:[NSMenuItem separatorItem]] ;
    meCocoaMenuAdd(menu,@"Save",@"s",NSEventModifierFlagCommand,"save-buffer") ;
    meCocoaMenuAdd(menu,@"Save As...",nil,0,"write-buffer") ;
    meCocoaMenuAdd(menu,@"Save All",nil,0,"save-some-buffers") ;
    [menu addItem:[NSMenuItem separatorItem]] ;
    meCocoaMenuAdd(menu,@"Close Buffer",@"w",NSEventModifierFlagCommand,"delete-buffer") ;
    meCocoaMenuAdd(menu,@"List Buffers",nil,0,"list-buffers") ;
    [menu addItem:[NSMenuItem separatorItem]] ;
    meCocoaMenuAdd(menu,@"Print...",@"p",NSEventModifierFlagCommand,"print-buffer") ;

    /* ---- Edit menu -------------------------------------------------- */
    item = [bar addItemWithTitle:@"Edit" action:NULL keyEquivalent:@""] ;
    menu = [[NSMenu alloc] initWithTitle:@"Edit"] ;
    [item setSubmenu:menu] ;
    meCocoaMenuAdd(menu,@"Undo",@"z",NSEventModifierFlagCommand,"undo") ;
    [menu addItem:[NSMenuItem separatorItem]] ;
    meCocoaMenuAdd(menu,@"Cut",@"x",NSEventModifierFlagCommand,"kill-region") ;
    meCocoaMenuAdd(menu,@"Copy",@"c",NSEventModifierFlagCommand,"copy-region") ;
    meCocoaMenuAdd(menu,@"Paste",@"v",NSEventModifierFlagCommand,"yank") ;
    [menu addItem:[NSMenuItem separatorItem]] ;
    item = [menu addItemWithTitle:@"Select All"
                           action:@selector(meCommand:) keyEquivalent:@"a"] ;
    [item setKeyEquivalentModifierMask:NSEventModifierFlagCommand] ;
    [item setTarget:meAppDelegate] ;
    [item setRepresentedObject:@[@"beginning-of-buffer",@"set-mark",@"end-of-buffer"]] ;
    [menu addItem:[NSMenuItem separatorItem]] ;
    meCocoaMenuAdd(menu,@"Find...",@"f",NSEventModifierFlagCommand,"search-forward") ;
    meCocoaMenuAdd(menu,@"Find Next",@"g",NSEventModifierFlagCommand,"hunt-forward") ;
    meCocoaMenuAdd(menu,@"Find Previous",nil,0,"hunt-backward") ;
    meCocoaMenuAdd(menu,@"Incremental Search",nil,0,"isearch-forward") ;
    meCocoaMenuAdd(menu,@"Replace...",nil,0,"query-replace-string") ;
    [menu addItem:[NSMenuItem separatorItem]] ;
    meCocoaMenuAdd(menu,@"Go to Line...",@"l",NSEventModifierFlagCommand,"goto-line") ;

    /* ---- View menu -------------------------------------------------- */
    item = [bar addItemWithTitle:@"View" action:NULL keyEquivalent:@""] ;
    menu = [[NSMenu alloc] initWithTitle:@"View"] ;
    [item setSubmenu:menu] ;
    item = [menu addItemWithTitle:@"Bigger Font"
                           action:@selector(meFontBigger:) keyEquivalent:@"+"] ;
    [item setKeyEquivalentModifierMask:NSEventModifierFlagCommand] ;
    [item setTarget:meAppDelegate] ;
    item = [menu addItemWithTitle:@"Smaller Font"
                           action:@selector(meFontSmaller:) keyEquivalent:@"-"] ;
    [item setKeyEquivalentModifierMask:NSEventModifierFlagCommand] ;
    [item setTarget:meAppDelegate] ;
    item = [menu addItemWithTitle:@"Actual Size"
                           action:@selector(meFontDefault:) keyEquivalent:@"0"] ;
    [item setKeyEquivalentModifierMask:NSEventModifierFlagCommand] ;
    [item setTarget:meAppDelegate] ;
    meCocoaMenuAdd(menu,@"Change Font...",nil,0,"change-font") ;
    [menu addItem:[NSMenuItem separatorItem]] ;
    meCocoaMenuAdd(menu,@"Split Window",@"2",NSEventModifierFlagCommand,"split-window-vertically") ;
    meCocoaMenuAdd(menu,@"Delete Window",@"1",NSEventModifierFlagCommand,"delete-other-windows") ;
    meCocoaMenuAdd(menu,@"Next Window",nil,0,"next-window") ;
    [menu addItem:[NSMenuItem separatorItem]] ;
    meCocoaMenuAdd(menu,@"Redraw Screen",nil,0,"screen-update") ;

    /* ---- Window menu ------------------------------------------------ */
    item = [bar addItemWithTitle:@"Window" action:NULL keyEquivalent:@""] ;
    menu = [[NSMenu alloc] initWithTitle:@"Window"] ;
    [item setSubmenu:menu] ;
    [menu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:)
             keyEquivalent:@"m"] ;
    [menu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""] ;
    item = [menu addItemWithTitle:@"Enter Full Screen"
                           action:@selector(toggleFullScreen:) keyEquivalent:@"f"] ;
    [item setKeyEquivalentModifierMask:NSEventModifierFlagCommand|NSEventModifierFlagControl] ;
    [menu addItem:[NSMenuItem separatorItem]] ;
    meCocoaMenuAdd(menu,@"New Frame",nil,0,"create-frame") ;
    meCocoaMenuAdd(menu,@"Next Frame",@"`",NSEventModifierFlagCommand,"next-frame") ;
    meCocoaMenuAdd(menu,@"Delete Frame",nil,0,"delete-frame") ;
    [NSApp setWindowsMenu:menu] ;

    /* ---- Help menu -------------------------------------------------- */
    item = [bar addItemWithTitle:@"Help" action:NULL keyEquivalent:@""] ;
    menu = [[NSMenu alloc] initWithTitle:@"Help"] ;
    [item setSubmenu:menu] ;
    meCocoaMenuAdd(menu,[appName stringByAppendingString:@" Help"],
                   @"?",NSEventModifierFlagCommand,"help") ;
    meCocoaMenuAdd(menu,@"Describe Key",nil,0,"describe-key") ;
    meCocoaMenuAdd(menu,@"Command Apropos",nil,0,"command-apropos") ;
    [NSApp setHelpMenu:menu] ;

    [NSApp setMainMenu:bar] ;
}

/**************************************************************************
* Fonts                                                                   *
**************************************************************************/

/*
 * meCocoaFontFree
 * Discard the cached font styles.
 */
static void
meCocoaFontFree(void)
{
    int ii ;

    for(ii=0 ; ii<meFONT_MAX ; ii++)
    {
        if(meFontTbl[ii].font != NULL)
        {
            CFRelease(meFontTbl[ii].font) ;
            meFontTbl[ii].font = NULL ;
        }
        meFontTbl[ii].loaded = 0 ;
    }
}

/*
 * meCocoaFontGet
 * Return the font for the given style, deriving bold and italic variants of
 * the base font on demand. The underline bit is not a separate font, the line
 * is drawn afterwards.
 */
static meCocoaFont *
meCocoaFontGet(meUByte font)
{
    meUByte fontNU = (font & ~(meFONT_UNDERLINE|meFONT_REVERSE)) & (meFONT_MAX-1) ;
    meCocoaFont *fnt = meFontTbl + fontNU ;

    if(fnt->loaded)
        return fnt ;

    if(fnt->font == NULL)
    {
        CTFontSymbolicTraits traits = 0 ;

        if(fontNU & meFONT_BOLD)
            traits |= kCTFontTraitBold ;
        if(fontNU & meFONT_ITALIC)
            traits |= kCTFontTraitItalic ;

        if((traits == 0) || (meFontTbl[0].font == NULL))
            fnt->font = (meFontTbl[0].font != NULL) ?
                (CTFontRef) CFRetain(meFontTbl[0].font):NULL ;
        else
        {
            fnt->font = CTFontCreateCopyWithSymbolicTraits(meFontTbl[0].font,0.0,
                                                           NULL,traits,traits) ;
            /* The family may not have the variant, fall back on the base */
            if(fnt->font == NULL)
                fnt->font = (CTFontRef) CFRetain(meFontTbl[0].font) ;
        }
    }
    if(fnt->font == NULL)
        return meFontTbl ;

    /* Build the character to glyph translation for the whole 8-bit range */
    {
        UniChar chars[256] ;
        CGSize advances[256] ;
        int ii ;

        for(ii=0 ; ii<256 ; ii++)
            chars[ii] = (UniChar) ii ;
        memset(fnt->glyph,0,sizeof(fnt->glyph)) ;
        CTFontGetGlyphsForCharacters(fnt->font,chars,fnt->glyph,256) ;
        CTFontGetAdvancesForGlyphs(fnt->font,kCTFontOrientationHorizontal,
                                   fnt->glyph+'M',advances,1) ;
        fnt->xoff = (mecm.fwidth - advances[0].width) / 2.0 ;
        if(fnt->xoff < 0.0)
            fnt->xoff = 0.0 ;
        fnt->loaded = 1 ;
    }
    return fnt ;
}

/*
 * meCocoaSetFont
 * Establish the base font and derive the character cell metrics from it. The
 * cell is sized from the widest of the digit, upper and lower case advances so
 * that the grid holds for any reasonable monospaced face.
 */
static int
meCocoaSetFont(NSString *family, int size)
{
    NSFont *font = nil ;
    CTFontRef ctf ;
    CGGlyph glyphs[3] ;
    CGSize advances[3] ;
    UniChar probe[3] = { 'M', 'm', '0' } ;
    CGFloat width ;
    int ii ;

    if(size < meCOCOA_FONT_MIN)
        size = meCOCOA_FONT_MIN ;
    else if(size > meCOCOA_FONT_MAX)
        size = meCOCOA_FONT_MAX ;

    if(family != nil)
        font = [NSFont fontWithName:family size:(CGFloat) size] ;
    if(font == nil)
    {
        /* Try the faces that ship with the system in turn before falling back
         * on whatever the user has configured as their fixed pitch font */
        for(NSString *name in @[@"Menlo",@"SF Mono",@"Monaco",@"Courier New"])
            if((font = [NSFont fontWithName:name size:(CGFloat) size]) != nil)
                break ;
    }
    if(font == nil)
        font = [NSFont userFixedPitchFontOfSize:(CGFloat) size] ;
    if(font == nil)
        return meFALSE ;

    ctf = (CTFontRef) font ;

    /* The cell width - use the widest of the probe characters */
    CTFontGetGlyphsForCharacters(ctf,probe,glyphs,3) ;
    CTFontGetAdvancesForGlyphs(ctf,kCTFontOrientationHorizontal,glyphs,advances,3) ;
    width = advances[0].width ;
    for(ii=1 ; ii<3 ; ii++)
        if(advances[ii].width > width)
            width = advances[ii].width ;

    if((width < 1.0) || (CTFontGetAscent(ctf) + CTFontGetDescent(ctf) < 1.0))
        return meFALSE ;

    meCocoaFontFree() ;
    meFontTbl[0].font = (CTFontRef) CFRetain(ctf) ;

    mecm.fwidth    = (int) ceil(width) ;
    mecm.ascent    = (int) ceil(CTFontGetAscent(ctf)) ;
    mecm.descent   = (int) ceil(CTFontGetDescent(ctf)) ;
    mecm.fdepth    = mecm.ascent + mecm.descent ;
    mecm.fhdepth   = mecm.fdepth >> 1 ;
    mecm.fhwidth   = mecm.fwidth >> 1 ;
    mecm.underline = mecm.descent - 1 ;
    if(mecm.underline < 1)
        mecm.underline = 1 ;
    if((mecm.fadepth = mecm.fwidth+1) > mecm.fdepth)
        mecm.fadepth = mecm.fdepth ;
    mecm.fontSize  = size ;

    if(meFontFamily != [font familyName])
    {
        [meFontFamily release] ;
        meFontFamily = [[font familyName] copy] ;
    }

    /* mecm.fontName doubles as the "font styles are available" flag, exactly
     * as it does in the Xlib back-end */
    meNullFree(mecm.fontName) ;
    if(meSystemCfg & meSYSTEM_FONTS)
    {
        char buf[128] ;

        snprintf(buf,sizeof(buf),"%s-%d",[[font familyName] UTF8String],size) ;
        mecm.fontName = meStrdup((meUByte *) buf) ;
    }
    else
        mecm.fontName = NULL ;

    return meTRUE ;
}

/*
 * meCocoaFontChanged
 * The cell size has changed - resize every frames window and canvas and force
 * a complete repaint.
 */
static void
meCocoaFontChanged(void)
{
    meFrameData *fd ;

    meFrameLoopBegin() ;

    meFrameLoopContinue(loopFrame->flags & meFRAME_HIDDEN) ;

    if((fd = (meFrameData *) loopFrame->termData) != NULL)
    {
        fd->font = 0 ;
        fd->fontCur = meCocoaFontGet(0) ;
        [fd->window setContentResizeIncrements:NSMakeSize(mecm.fwidth,mecm.fdepth)] ;
        [fd->window setContentMinSize:NSMakeSize(mecm.fwidth*10,mecm.fdepth*4)] ;
    }
    meFrameSetWindowSize(loopFrame) ;
    meCocoaFrameCanvasCreate(loopFrame) ;

    meFrameLoopEnd() ;

    sgarbf = meTRUE ;
}

/*
 * changeFont
 * The "change-font" command. The font is given as a family name with an
 * optional point size, e.g. "Menlo-14".
 */
int
changeFont(int f, int n)
{
    meUByte buff[meBUF_SIZE_MAX] ;
    meUByte *ss ;
    int size ;

    if(meSystemCfg & meSYSTEM_CONSOLE)
        /* change-font not supported on termcap */
        return notAvailable(f,n) ;

    if(meGetString((meUByte *)"Font Name", 0, 0, buff, meBUF_SIZE_MAX) == meABORT)
        return meFALSE ;

    /* Split off a trailing "-<size>" if there is one */
    size = mecm.fontSize ;
    if(((ss = meStrrchr(buff,'-')) != NULL) && isDigit(ss[1]))
    {
        size = meAtoi(ss+1) ;
        *ss = '\0' ;
    }

    @autoreleasepool
    {
        NSString *family = (buff[0] != '\0') ?
            [NSString stringWithUTF8String:(char *) buff]:nil ;

        if(meCocoaSetFont(family,size) == meFALSE)
        {
            /* Put the old font back so that we are not left without one */
            meCocoaSetFont(meFontFamily,mecm.fontSize) ;
            return mlwrite(MWABORT,(meUByte *)"[Cannot load font %s]",buff) ;
        }
    }
    meCocoaFontChanged() ;
    return meTRUE ;
}

/**************************************************************************
* Canvas                                                                  *
**************************************************************************/

static void
meCocoaFrameCanvasFree(meFrameData *fd)
{
    if(fd->ctx != NULL)
    {
        CGContextRelease(fd->ctx) ;
        fd->ctx = NULL ;
    }
}

/*
 * meCocoaFrameCanvasCreate
 * (Re)create the offscreen canvas that the drawing primitives paint into. The
 * canvas is sized to the views bounds, scaled up for a retina display, and is
 * addressed in points with a top-left origin so that the editors row and
 * column arithmetic needs no adjustment.
 */
static void
meCocoaFrameCanvasCreate(meFrame *frame)
{
    meFrameData *fd ;
    CGColorSpaceRef cs ;
    NSSize sz ;
    NSEdgeInsets insets ;
    CGFloat scale, originX, originY ;
    int pw, pd, bw, bd ;
    size_t stride ;

    if((frame == NULL) || ((fd = (meFrameData *) frame->termData) == NULL))
        return ;

    insets = meCocoaSafeAreaInsets(fd->view) ;
    sz = meCocoaInsetSize([fd->view bounds].size,insets) ;
    if(sz.width < 0.0)
        sz.width = 0.0 ;
    if(sz.height < 0.0)
        sz.height = 0.0 ;
    originX = insets.left ;
    originY = insets.top ;
    scale = [fd->window backingScaleFactor] ;
    if(scale < 1.0)
        scale = 1.0 ;
    /* The canvas holds whole character cells only - the window is rarely an
     * exact multiple of the cell size and the slack is filled by the view */
    pw = (((int) sz.width) / mecm.fwidth) * mecm.fwidth ;
    pd = (((int) sz.height) / mecm.fdepth) * mecm.fdepth ;
    if(pw < mecm.fwidth)
        pw = mecm.fwidth ;
    if(pd < mecm.fdepth)
        pd = mecm.fdepth ;

    if((fd->ctx != NULL) && (fd->pwidth == pw) && (fd->pdepth == pd) &&
       (fd->scale == scale) && (fd->originX == originX) && (fd->originY == originY))
        return ;                        /* Nothing has changed */

    fd->originX = originX ;
    fd->originY = originY ;

    bw = (int) (pw * scale) ;
    bd = (int) (pd * scale) ;
    stride = ((size_t) bw) * 4 ;

    meCocoaFrameCanvasFree(fd) ;

    /* CoreGraphics owns the pixels - an image made from the context may
     * outlive us in the window servers hands, so it must manage the buffer */
    cs = CGColorSpaceCreateDeviceRGB() ;
    fd->ctx = CGBitmapContextCreate(NULL,bw,bd,8,stride,cs,
                                    kCGImageAlphaNoneSkipFirst |
                                    kCGBitmapByteOrder32Host) ;
    CGColorSpaceRelease(cs) ;
    if(fd->ctx == NULL)
        return ;
    fd->pwidth = pw ;
    fd->pdepth = pd ;
    fd->scale  = scale ;

    /* Work in points with y running down the screen */
    CGContextScaleCTM(fd->ctx,scale,scale) ;
    CGContextTranslateCTM(fd->ctx,0.0,pd) ;
    CGContextScaleCTM(fd->ctx,1.0,-1.0) ;
    CGContextSetShouldAntialias(fd->ctx,true) ;
    CGContextSetLineWidth(fd->ctx,1.0) ;

    /* Start from the global background colour rather than black */
    if(noColors > 0)
    {
        meUInt col = colTable[meStyleGetBColor(meSchemeGetStyle(globScheme))] ;
        CGContextSetRGBFillColor(fd->ctx,meColRed(col),meColGreen(col),
                                 meColBlue(col),1.0) ;
        CGContextFillRect(fd->ctx,CGRectMake(0.0,0.0,pw,pd)) ;
    }

    /* The cached colours and font in the frame no longer apply */
    fd->fcol = meCOLOR_FDEFAULT ;
    fd->bcol = meCOLOR_BDEFAULT ;
    fd->cgcol = meCOLOR_INVALID ;
    fd->font = 0 ;
    fd->fontCur = meCocoaFontGet(0) ;
    fd->hasDirty = 0 ;
    [fd->view setNeedsDisplay:YES] ;
}

/*
 * meCocoaDirty
 * Accumulate the region of the canvas that has been painted so that the blit
 * on the next flush is no bigger than it has to be.
 */
static void
meCocoaDirty(meFrameData *fd, CGRect rect)
{
    if(fd->hasDirty)
        fd->dirty = CGRectUnion(fd->dirty,rect) ;
    else
    {
        fd->dirty = rect ;
        fd->hasDirty = 1 ;
    }
}

void
meCocoaFlush(void)
{
    meFrameData *fd ;

    @autoreleasepool
    {
        meFrameLoopBegin() ;

        meFrameLoopContinue(loopFrame->flags & meFRAME_HIDDEN) ;

        if((fd = (meFrameData *) loopFrame->termData) != NULL)
        {
            if(fd->hasDirty)
            {
                [fd->view setNeedsDisplayInRect:NSRectFromCGRect(fd->dirty)] ;
                fd->hasDirty = 0 ;
            }
            [fd->view displayIfNeeded] ;
        }
        meFrameLoopEnd() ;
    }
}

/**************************************************************************
* Drawing primitives                                                      *
**************************************************************************/

/*
 * meFrameXTermSetScheme
 * Select the colours and font of the given scheme, ready for the next draw.
 */
void
meFrameXTermSetScheme(meFrame *frame, meScheme scheme)
{
    meFrameData *fd = (meFrameData *) frame->termData ;
    meUByte cc ;

    if((fd == NULL) || (fd->ctx == NULL))
        return ;

    fd->fcol = meStyleGetFColor(meSchemeGetStyle(scheme)) ;
    fd->bcol = meStyleGetBColor(meSchemeGetStyle(scheme)) ;

    if(mecm.fontName != NULL)
    {
        cc = meStyleGetFont(meSchemeGetStyle(scheme)) ;
        if(meSchemeTestNoFont(scheme))
            cc &= ~(meFONT_BOLD|meFONT_ITALIC|meFONT_UNDERLINE) ;
        if(fd->font != cc)
        {
            fd->font = cc ;
            fd->fontCur = meCocoaFontGet(cc) ;
        }
    }
}

/*
 * meCocoaSetColor
 * Load a colour table entry into the canvas as both the fill and the stroke
 * colour, remembering which one is current so that a run of drawing in one
 * colour does not keep re-stating it.
 */
static void
meCocoaSetColor(meFrameData *fd, meUByte index)
{
    meUInt col ;

    if(fd->cgcol == index)
        return ;
    fd->cgcol = index ;
    col = colTable[(index < noColors) ? index:meCOLOR_FDEFAULT] ;
    CGContextSetRGBFillColor(fd->ctx,meColRed(col),meColGreen(col),
                             meColBlue(col),1.0) ;
    CGContextSetRGBStrokeColor(fd->ctx,meColRed(col),meColGreen(col),
                               meColBlue(col),1.0) ;
}

/*
 * meCocoaDrawString
 * Paint a run of text. As with the X11 XDrawImageString this fills the
 * character cells with the background colour and then draws the glyphs, one
 * per cell, so that the grid is exact whatever the font advance.
 *
 * x is the left hand edge of the run, y is the text baseline.
 */
void
meCocoaDrawString(meFrame *frame, int x, int y, meUByte *str, int len)
{
    meFrameData *fd = (meFrameData *) frame->termData ;
    meCocoaFont *fnt ;
    CGGlyph glyphs[meBUF_SIZE_MAX] ;
    CGPoint pos[meBUF_SIZE_MAX] ;
    CGRect cells ;
    int ii ;

    if((fd == NULL) || (fd->ctx == NULL) || (len <= 0))
        return ;
    if(len > meBUF_SIZE_MAX)
        len = meBUF_SIZE_MAX ;

    cells = CGRectMake(x,y-mecm.ascent,len*mecm.fwidth,mecm.fdepth) ;

    /* Erase the cells to the background colour */
    meCocoaSetColor(fd,fd->bcol) ;
    CGContextFillRect(fd->ctx,cells) ;

    /* Then lay the glyphs into the cells */
    if((fnt = fd->fontCur) == NULL)
        fnt = fd->fontCur = meCocoaFontGet(fd->font) ;
    if((fnt != NULL) && (fnt->font != NULL))
    {
        int nn = 0 ;

        /* One glyph per byte from the 8-bit glyph table, matching the
         * X11 back-end - see meCocoaKeyEvent for why the buffer is byte
         * oriented */
        for(ii=0 ; ii<len ; ii++)
        {
            meUByte b0 = str[ii] ;

            if(fnt->glyph[b0] != 0)
            {
                glyphs[nn] = fnt->glyph[b0] ;
                pos[nn] = CGPointMake(x + (ii*mecm.fwidth) + fnt->xoff,0.0) ;
                nn++ ;
            }
        }
        meCocoaSetColor(fd,fd->fcol) ;

        /* The glyph positions are in text space, which the canvas transform
         * would mirror, so put the origin on the baseline and undo the y flip
         * for the duration of the draw */
        CGContextSaveGState(fd->ctx) ;
        CGContextTranslateCTM(fd->ctx,0.0,y) ;
        CGContextScaleCTM(fd->ctx,1.0,-1.0) ;
        CGContextSetTextMatrix(fd->ctx,CGAffineTransformIdentity) ;
        if(nn > 0)
            CTFontDrawGlyphs(fnt->font,glyphs,pos,nn,fd->ctx) ;
        CGContextRestoreGState(fd->ctx) ;

        if(fd->font & meFONT_UNDERLINE)
        {
            CGContextBeginPath(fd->ctx) ;
            CGContextMoveToPoint(fd->ctx,x,y+mecm.underline+0.5) ;
            CGContextAddLineToPoint(fd->ctx,x+(len*mecm.fwidth),
                                    y+mecm.underline+0.5) ;
            CGContextStrokePath(fd->ctx) ;
        }
    }
    meCocoaDirty(fd,cells) ;
}

/*
 * The line and polygon helpers used by the special character renderer. X11
 * line ends are inclusive and a pixel wide, the half pixel offsets reproduce
 * that on a Quartz canvas.
 */
static void
meCocoaLine(meFrameData *fd, int x1, int y1, int x2, int y2)
{
    CGContextBeginPath(fd->ctx) ;
    if(y1 == y2)
    {
        CGContextMoveToPoint(fd->ctx,(x1 < x2) ? x1:x2+1,y1+0.5) ;
        CGContextAddLineToPoint(fd->ctx,(x1 < x2) ? x2+1:x1,y1+0.5) ;
    }
    else if(x1 == x2)
    {
        CGContextMoveToPoint(fd->ctx,x1+0.5,(y1 < y2) ? y1:y2+1) ;
        CGContextAddLineToPoint(fd->ctx,x1+0.5,(y1 < y2) ? y2+1:y1) ;
    }
    else
    {
        CGContextMoveToPoint(fd->ctx,x1+0.5,y1+0.5) ;
        CGContextAddLineToPoint(fd->ctx,x2+0.5,y2+0.5) ;
    }
    CGContextStrokePath(fd->ctx) ;
}

static void
meCocoaPoly(meFrameData *fd, const CGPoint *pts, int count)
{
    int ii ;

    CGContextBeginPath(fd->ctx) ;
    CGContextMoveToPoint(fd->ctx,pts[0].x,pts[0].y) ;
    for(ii=1 ; ii<count ; ii++)
        CGContextAddLineToPoint(fd->ctx,pts[ii].x,pts[ii].y) ;
    CGContextClosePath(fd->ctx) ;
    CGContextFillPath(fd->ctx) ;
}

/*
 * meFrameXTermDrawSpecialChar
 * Draw one of the editors internal graphics characters. x is the left hand
 * edge of the character, y is the top of the character and the current
 * foreground colour is used.
 */
void
meFrameXTermDrawSpecialChar(meFrame *frame, int x, int y, meUByte cc)
{
    meFrameData *fd = (meFrameData *) frame->termData ;
    CGPoint points[4] ;
    int ii ;

    if((fd == NULL) || (fd->ctx == NULL))
        return ;

    meCocoaSetColor(fd,fd->fcol) ;

    switch(cc)
    {
    case 0x01:          /* checkbox left side ([) */
        meCocoaLine(fd,x + mecm.fwidth - 1, y + mecm.fhdepth - mecm.fhwidth,
                       x + mecm.fwidth - 2, y + mecm.fhdepth - mecm.fhwidth) ;
        meCocoaLine(fd,x + mecm.fwidth - 2, y + mecm.fhdepth - mecm.fhwidth,
                       x + mecm.fwidth - 2, y + mecm.fhdepth + mecm.fwidth - mecm.fhwidth) ;
        meCocoaLine(fd,x + mecm.fwidth - 2, y + mecm.fhdepth + mecm.fwidth - mecm.fhwidth,
                       x + mecm.fwidth - 1, y + mecm.fhdepth + mecm.fwidth - mecm.fhwidth) ;
        break ;

    case 0x02:          /* checkbox center not selected */
        meCocoaLine(fd,x, y + mecm.fhdepth - mecm.fhwidth,
                       x + mecm.fwidth - 1, y + mecm.fhdepth - mecm.fhwidth) ;
        meCocoaLine(fd,x, y + mecm.fhdepth + mecm.fwidth - mecm.fhwidth,
                       x + mecm.fwidth - 1, y + mecm.fhdepth + mecm.fwidth - mecm.fhwidth) ;
        break ;

    case 0x03:          /* checkbox center selected */
        meCocoaLine(fd,x, y + mecm.fhdepth - mecm.fhwidth,
                       x + mecm.fwidth - 1, y + mecm.fhdepth - mecm.fhwidth) ;
        meCocoaLine(fd,x, y + mecm.fhdepth + mecm.fwidth - mecm.fhwidth,
                       x + mecm.fwidth - 1, y + mecm.fhdepth + mecm.fwidth - mecm.fhwidth) ;
        points[0] = CGPointMake(x, y + mecm.fhdepth - mecm.fhwidth + 2) ;
        points[1] = CGPointMake(x, y + mecm.fhdepth + mecm.fwidth - mecm.fhwidth - 1) ;
        points[2] = CGPointMake(x + mecm.fwidth, y + mecm.fhdepth + mecm.fwidth - mecm.fhwidth - 1) ;
        points[3] = CGPointMake(x + mecm.fwidth, y + mecm.fhdepth - mecm.fhwidth + 2) ;
        meCocoaPoly(fd,points,4) ;
        break ;

    case 0x04:          /* checkbox right side (]) */
        meCocoaLine(fd,x, y + mecm.fhdepth - mecm.fhwidth,
                       x + 1, y + mecm.fhdepth - mecm.fhwidth) ;
        meCocoaLine(fd,x + 1, y + mecm.fhdepth - mecm.fhwidth,
                       x + 1, y + mecm.fhdepth + mecm.fwidth - mecm.fhwidth) ;
        meCocoaLine(fd,x + 1, y + mecm.fhdepth + mecm.fwidth - mecm.fhwidth,
                       x, y + mecm.fhdepth + mecm.fwidth - mecm.fhwidth) ;
        break ;

    case 0x07:          /* Line space '.' */
        meCocoaLine(fd,x+mecm.fhwidth, y+mecm.fhdepth,
                       x+mecm.fhwidth+1, y+mecm.fhdepth) ;
        break ;

    case 0x08:          /* Backspace character <- */
        ii = (mecm.fhdepth+1) >> 1 ;
        meCocoaLine(fd,x+mecm.fwidth-2, y+mecm.fhdepth,
                       x+mecm.fhwidth, y+mecm.fhdepth) ;
        points[0] = CGPointMake(x+mecm.fhwidth, y+ii) ;
        points[1] = CGPointMake(x+mecm.fhwidth, y+mecm.fdepth-ii-1) ;
        points[2] = CGPointMake(x+1, y+mecm.fhdepth) ;
        meCocoaPoly(fd,points,3) ;
        break ;

    case 0x09:          /* Tab character -> */
        ii = (mecm.fhdepth+1) >> 1 ;
        meCocoaLine(fd,x+1, y+mecm.fhdepth, x+mecm.fhwidth-1, y+mecm.fhdepth) ;
        points[0] = CGPointMake(x+mecm.fhwidth-1, y+ii) ;
        points[1] = CGPointMake(x+mecm.fhwidth-1, y+mecm.fdepth-ii-1) ;
        points[2] = CGPointMake(x+mecm.fwidth-2, y+mecm.fhdepth) ;
        meCocoaPoly(fd,points,3) ;
        break ;

    case 0x0a:          /* CR character / <-| */
        ii = (mecm.fhdepth+1) >> 1 ;
        meCocoaLine(fd,x+mecm.fhwidth, y+mecm.fhdepth,
                       x+mecm.fwidth-2, y+mecm.fhdepth) ;
        meCocoaLine(fd,x+mecm.fwidth-2, y+mecm.fhdepth,
                       x+mecm.fwidth-2, y+ii-1) ;
        points[0] = CGPointMake(x+mecm.fhwidth, y+ii) ;
        points[1] = CGPointMake(x+mecm.fhwidth, y+mecm.fdepth-ii-1) ;
        points[2] = CGPointMake(x+1, y+mecm.fhdepth) ;
        meCocoaPoly(fd,points,3) ;
        break ;

    case 0x0b:          /* Line Drawing / Bottom right _| */
        meCocoaLine(fd,x, y + mecm.fhdepth, x + mecm.fhwidth, y + mecm.fhdepth) ;
        meCocoaLine(fd,x + mecm.fhwidth, y + mecm.fhdepth, x + mecm.fhwidth, y) ;
        break ;

    case 0x0c:          /* Line Drawing / Top right */
        meCocoaLine(fd,x, y + mecm.fhdepth, x + mecm.fhwidth, y + mecm.fhdepth) ;
        meCocoaLine(fd,x + mecm.fhwidth, y + mecm.fhdepth,
                       x + mecm.fhwidth, y + mecm.fdepth - 1) ;
        break ;

    case 0x0d:          /* Line Drawing / Top left */
        meCocoaLine(fd,x + mecm.fwidth - 1, y + mecm.fhdepth,
                       x + mecm.fhwidth, y + mecm.fhdepth) ;
        meCocoaLine(fd,x + mecm.fhwidth, y + mecm.fhdepth,
                       x + mecm.fhwidth, y + mecm.fdepth - 1) ;
        break ;

    case 0x0e:          /* Line Drawing / Bottom left |_ */
        meCocoaLine(fd,x + mecm.fhwidth, y, x + mecm.fhwidth, y + mecm.fhdepth) ;
        meCocoaLine(fd,x + mecm.fhwidth, y + mecm.fhdepth,
                       x + mecm.fwidth - 1, y + mecm.fhdepth) ;
        break ;

    case 0x0f:          /* Line Drawing / Centre cross + */
        meCocoaLine(fd,x, y + mecm.fhdepth, x + mecm.fwidth - 1, y + mecm.fhdepth) ;
        meCocoaLine(fd,x + mecm.fhwidth, y, x + mecm.fhwidth, y + mecm.fdepth - 1) ;
        break ;

    case 0x10:          /* Cursor Arrows / Right */
        ii = (mecm.fwidth > mecm.fhdepth) ? mecm.fhdepth:mecm.fwidth ;
        points[0] = CGPointMake(x + 1, y + mecm.fhdepth - ii) ;
        points[1] = CGPointMake(x + 1, y + mecm.fhdepth + ii) ;
        points[2] = CGPointMake(x + ii + 1, y + mecm.fhdepth) ;
        meCocoaPoly(fd,points,3) ;
        break ;

    case 0x11:          /* Cursor Arrows / Left */
        ii = (mecm.fwidth > mecm.fhdepth) ? mecm.fhdepth:mecm.fwidth ;
        points[0] = CGPointMake(x + mecm.fwidth - 1, y + mecm.fhdepth + ii) ;
        points[1] = CGPointMake(x + mecm.fwidth - 1, y + mecm.fhdepth - ii) ;
        points[2] = CGPointMake(x + mecm.fwidth - 1 - ii, y + mecm.fhdepth) ;
        meCocoaPoly(fd,points,3) ;
        break ;

    case 0x12:          /* Line Drawing / Horizontal line - */
        meCocoaLine(fd,x, y + mecm.fhdepth, x + mecm.fwidth - 1, y + mecm.fhdepth) ;
        break ;

    case 0x13:          /* cross box empty ([ ]) */
    case 0x14:          /* cross box ([X]) */
        meCocoaLine(fd,x, y + mecm.fhdepth - mecm.fhwidth + 1,
                       x + mecm.fwidth - 1, y + mecm.fhdepth - mecm.fhwidth + 1) ;
        meCocoaLine(fd,x, y + mecm.fhdepth + mecm.fwidth - mecm.fhwidth,
                       x + mecm.fwidth - 1, y + mecm.fhdepth + mecm.fwidth - mecm.fhwidth) ;
        meCocoaLine(fd,x, y + mecm.fhdepth - mecm.fhwidth + 1,
                       x, y + mecm.fhdepth + mecm.fwidth - mecm.fhwidth) ;
        meCocoaLine(fd,x + mecm.fwidth - 1, y + mecm.fhdepth - mecm.fhwidth + 1,
                       x + mecm.fwidth - 1, y + mecm.fhdepth + mecm.fwidth - mecm.fhwidth) ;
        if(cc == 0x14)
        {
            meCocoaLine(fd,x, y + mecm.fhdepth - mecm.fhwidth + 1,
                           x + mecm.fwidth - 1, y + mecm.fhdepth + mecm.fwidth - mecm.fhwidth) ;
            meCocoaLine(fd,x, y + mecm.fhdepth + mecm.fwidth - mecm.fhwidth,
                           x + mecm.fwidth - 1, y + mecm.fhdepth - mecm.fhwidth + 1) ;
        }
        break ;

    case 0x15:          /* Line Drawing / Left Tee |- */
        meCocoaLine(fd,x + mecm.fhwidth, y, x + mecm.fhwidth, y + mecm.fdepth - 1) ;
        meCocoaLine(fd,x + mecm.fhwidth, y + mecm.fhdepth,
                       x + mecm.fwidth - 1, y + mecm.fhdepth) ;
        break ;

    case 0x16:          /* Line Drawing / Right Tee -| */
        meCocoaLine(fd,x + mecm.fhwidth, y, x + mecm.fhwidth, y + mecm.fdepth - 1) ;
        meCocoaLine(fd,x, y + mecm.fhdepth, x + mecm.fhwidth, y + mecm.fhdepth) ;
        break ;

    case 0x17:          /* Line Drawing / Bottom Tee _|_ */
        meCocoaLine(fd,x, y + mecm.fhdepth, x + mecm.fwidth - 1, y + mecm.fhdepth) ;
        meCocoaLine(fd,x + mecm.fhwidth, y, x + mecm.fhwidth, y + mecm.fhdepth) ;
        break ;

    case 0x18:          /* Line Drawing / Top Tee -|- */
        meCocoaLine(fd,x, y + mecm.fhdepth, x + mecm.fwidth - 1, y + mecm.fhdepth) ;
        meCocoaLine(fd,x + mecm.fhwidth, y + mecm.fdepth - 1,
                       x + mecm.fhwidth, y + mecm.fhdepth) ;
        break ;

    case 0x19:          /* Line Drawing / Vertical Line | */
        meCocoaLine(fd,x + mecm.fhwidth, y, x + mecm.fhwidth, y + mecm.fdepth - 1) ;
        break ;

    case 0x1a:          /* Line Drawing / Bottom right _| with resize */
        meCocoaLine(fd,x, y + mecm.fhdepth, x + mecm.fhwidth, y + mecm.fhdepth) ;
        meCocoaLine(fd,x + mecm.fhwidth, y + mecm.fhdepth, x + mecm.fhwidth, y) ;
        meCocoaLine(fd,x, y + mecm.fdepth - 1,
                       x + mecm.fwidth - 1, y + mecm.fdepth - mecm.fwidth) ;
        meCocoaLine(fd,x + 2, y + mecm.fdepth - 1,
                       x + mecm.fwidth - 1, y + mecm.fdepth - mecm.fwidth + 2) ;
        meCocoaLine(fd,x + 4, y + mecm.fdepth - 1,
                       x + mecm.fwidth - 1, y + mecm.fdepth - mecm.fwidth + 4) ;
        break ;

    case 0x1b:          /* Scroll box - vertical */
        for(ii = (y+1) & ~1 ; ii < y+mecm.fdepth ; ii += 2)
            meCocoaLine(fd,x, ii, x + mecm.fwidth - 1, ii) ;
        break ;

    case 0x1d:          /* Scroll box - horizontal */
        for(ii = (x+1) & ~1 ; ii < x+mecm.fwidth ; ii += 2)
            meCocoaLine(fd,ii, y, ii, y + mecm.fdepth - 1) ;
        break ;

    case 0x1e:          /* Cursor Arrows / Up */
        points[0] = CGPointMake(x - 1, y + mecm.fdepth - 1) ;
        points[1] = CGPointMake(points[0].x + mecm.fhwidth + (mecm.fwidth & 0x01),
                                points[0].y - mecm.fadepth) ;
        points[2] = CGPointMake(points[1].x + mecm.fhwidth + 1,
                                points[1].y + mecm.fadepth) ;
        meCocoaPoly(fd,points,3) ;
        break ;

    case 0x1f:          /* Cursor Arrows / Down */
        points[0] = CGPointMake(x - 1, y + 1) ;
        points[1] = CGPointMake(points[0].x + mecm.fhwidth + (mecm.fwidth & 0x01),
                                points[0].y + mecm.fadepth) ;
        points[2] = CGPointMake(points[1].x + mecm.fhwidth + 1,
                                points[1].y - mecm.fadepth) ;
        meCocoaPoly(fd,points,3) ;
        break ;
    }
    meCocoaDirty(fd,CGRectMake(x,y,mecm.fwidth,mecm.fdepth)) ;
}

/*
 * meFrameXTermDraw
 * Repaint the screen for the specified region from the frame store. We use the
 * colour and text information from the frame store and re-paint it on the
 * canvas, thereby refreshing the screen.
 */
void
meFrameXTermDraw(meFrame *frame, int srow, int scol, int erow, int ecol)
{
    meFrameLine *flp ;                  /* Frame store line pointer */
    meScheme  *fssp ;                   /* Frame store colour pointer */
    meUByte   *fstp ;                   /* Frame store text pointer */
    meScheme   schm ;                   /* Current colour */
    int col ;                           /* Current column position */
    int row ;                           /* Current row screen position */
    int tcol ;                          /* Text column start */
    int length ;                        /* Length of string */

    if(frame->termData == NULL)
        return ;

    /* Process each row in turn until we reach the end of the line */
    if(meSystemCfg & meSYSTEM_FONTFIX)
    {
        meUByte cc, *sfstp, buff[meBUF_SIZE_MAX] ;
        int spFlag ;

        for(flp = frame->store + srow ; srow < erow ; srow++, flp++)
        {
            length = 0 ;                /* Initialise the string length */
            col = scol ;                /* Current column becomes start column */
            tcol = col ;                /* Start of the text column */
            row = rowToClient(srow) ;

            /* Get pointers aligned into the frame store */
            sfstp = flp->text ;
            fstp = sfstp + scol ;       /* Point to text block */
            fssp = flp->scheme + scol ; /* Point to colour block */
            schm = *fssp ;              /* Get the initial scheme */
            spFlag = 0 ;
            while(col < ecol)
            {
                if(*fssp++ != schm)     /* Change in colour ?? */
                {
                    /* Output the current text item */
                    meFrameXTermSetScheme(frame,schm) ;
                    meFrameXTermDrawString(frame,colToClient(tcol),row,buff,length) ;
                    while(--spFlag >= 0)
                    {
                        while(((cc=sfstp[tcol]) & 0xe0) != 0)
                            tcol++ ;
                        meFrameXTermDrawSpecialChar(frame,tcol*mecm.fwidth,
                                                    row-mecm.ascent,cc) ;
                        tcol++ ;
                    }
                    spFlag = 0 ;
                    tcol = col ;        /* Move the text position */
                    length = 0 ;        /* Reset the length */
                    schm = fssp[-1] ;   /* Get the next colour */
                }
                if(((cc=*fstp++) & 0xe0) == 0)
                {
                    spFlag++ ;
                    cc = ' ' ;
                }
                buff[length++] = cc ;   /* Set & Increment the string length */
                col++ ;                 /* Next column */
            }

            /* Output the remaining text item */
            if(length > 0)
            {
                meFrameXTermSetScheme(frame,schm) ;
                meFrameXTermDrawString(frame,colToClient(tcol),row,buff,length) ;
                while(--spFlag >= 0)
                {
                    while(((cc=sfstp[tcol]) & 0xe0) != 0)
                        tcol++ ;
                    meFrameXTermDrawSpecialChar(frame,tcol*mecm.fwidth,
                                                row-mecm.ascent,cc) ;
                    tcol++ ;
                }
            }
        }
    }
    else
    {
        for(flp = frame->store + srow ; srow < erow ; srow++, flp++)
        {
            length = 0 ;                /* Initialise the string length */
            col = scol ;                /* Current column becomes start column */
            tcol = col ;                /* Start of the text column */

            /* Get pointers aligned into the frame store */
            fstp = flp->text + scol ;   /* Point to text block */
            fssp = flp->scheme + scol ; /* Point to colour block */
            schm = *fssp ;              /* Get the initial scheme */

            while(col < ecol)
            {
                if(*fssp++ != schm)     /* Change in colour ?? */
                {
                    /* Output the current text item */
                    meFrameXTermSetScheme(frame,schm) ;
                    meFrameXTermDrawString(frame,colToClient(tcol),
                                           rowToClient(srow),fstp,length) ;
                    fstp += length ;    /* Move the text pointer */
                    tcol = col ;        /* Move the text position */
                    length = 0 ;        /* Reset the length */
                    schm = fssp[-1] ;   /* Get the next colour */
                }
                length++ ;              /* Increment the string length */
                col++ ;                 /* Next column */
            }

            /* Output the remaining text item */
            if(length > 0)
            {
                meFrameXTermSetScheme(frame,schm) ;
                meFrameXTermDrawString(frame,colToClient(tcol),
                                       rowToClient(srow),fstp,length) ;
            }
        }
    }
}

/**************************************************************************
* Cursor                                                                  *
**************************************************************************/

/*
 * meFrameXTermHideCursor
 * Remove the cursor by redrawing the character underneath it.
 */
void
meFrameXTermHideCursor(meFrame *frame)
{
    if((frame->cursorRow <= frame->depth) && (frame->cursorColumn < frame->width))
    {
        meFrameLine *flp ;              /* Frame store line pointer */
        meUByte     *cc ;               /* Current char */
        meScheme     schm ;             /* Current colour */

        flp  = frame->store + frame->cursorRow ;
        cc   = flp->text+frame->cursorColumn ;
        schm = flp->scheme[frame->cursorColumn] ;

        meFrameXTermSetScheme(frame,schm) ;
        if((meSystemCfg & meSYSTEM_FONTFIX) && !((*cc) & 0xe0))
        {
            static meUByte ss[1] = { ' ' } ;
            meFrameXTermDrawString(frame,colToClient(frame->cursorColumn),
                                   rowToClient(frame->cursorRow),ss,1) ;
            meFrameXTermDrawSpecialChar(frame,colToClient(frame->cursorColumn),
                                        rowToClientTop(frame->cursorRow),*cc) ;
        }
        else
            meFrameXTermDrawString(frame,colToClient(frame->cursorColumn),
                                   rowToClient(frame->cursorRow),cc,1) ;
    }
}

/*
 * meFrameXTermShowCursor
 * Draw the cursor. When the frame has the focus this is a solid block in the
 * cursor colour, otherwise it is an outline.
 */
void
meFrameXTermShowCursor(meFrame *frame)
{
    meFrameData *fd = (meFrameData *) frame->termData ;

    if((fd == NULL) || (fd->ctx == NULL))
        return ;

    if((frame->cursorRow <= frame->depth) && (frame->cursorColumn < frame->width))
    {
        meFrameLine *flp ;              /* Frame store line pointer */
        meUByte     *cc ;               /* Current char */
        meScheme     schm ;             /* Current colour */

        flp  = frame->store + frame->cursorRow ;
        cc   = flp->text+frame->cursorColumn ;
        schm = flp->scheme[frame->cursorColumn] ;

        if(!(frame->flags & meFRAME_NOT_FOCUS))
        {
            meUByte ff ;

            /* The character is drawn in its own background colour on a block
             * of the cursor colour - i.e. reversed out */
            ff = meStyleGetBColor(meSchemeGetStyle(schm)) ;
            fd->fcol = ff ;
            fd->bcol = cursorColor ;

            if(mecm.fontName != NULL)
            {
                ff = meStyleGetFont(meSchemeGetStyle(schm)) ;
                if(meSchemeTestNoFont(schm))
                    ff &= ~(meFONT_BOLD|meFONT_ITALIC|meFONT_UNDERLINE) ;
                if(fd->font != ff)
                {
                    fd->font = ff ;
                    fd->fontCur = meCocoaFontGet(ff) ;
                }
            }
            if((meSystemCfg & meSYSTEM_FONTFIX) && !((*cc) & 0xe0))
            {
                static meUByte ss[1] = { ' ' } ;
                meFrameXTermDrawString(frame,colToClient(frame->cursorColumn),
                                       rowToClient(frame->cursorRow),ss,1) ;
                meFrameXTermDrawSpecialChar(frame,colToClient(frame->cursorColumn),
                                            rowToClientTop(frame->cursorRow),*cc) ;
            }
            else
                meFrameXTermDrawString(frame,colToClient(frame->cursorColumn),
                                       rowToClient(frame->cursorRow),cc,1) ;
        }
        else
        {
            CGRect rect ;

            meCocoaSetColor(fd,cursorColor) ;
            rect = CGRectMake(colToClient(frame->cursorColumn) + 0.5,
                              rowToClientTop(frame->cursorRow) + 0.5,
                              mecm.fwidth - 1, mecm.fdepth - 1) ;
            CGContextStrokeRect(fd->ctx,rect) ;
            meCocoaDirty(fd,CGRectMake(colToClient(frame->cursorColumn),
                                       rowToClientTop(frame->cursorRow),
                                       mecm.fwidth,mecm.fdepth)) ;
        }
    }
}

/**************************************************************************
* Colours                                                                 *
**************************************************************************/

int
XTERMaddColor(meColor index, meUByte r, meUByte g, meUByte b)
{
    if(noColors <= index)
    {
        colTable = (meUInt *) meRealloc(colTable,(index+1)*sizeof(meUInt)) ;
        memset(colTable+noColors,0,(index-noColors+1)*sizeof(meUInt)) ;
        noColors = index+1 ;
    }
    colTable[index] = (((meUInt) r) << 16) | (((meUInt) g) << 8) | ((meUInt) b) ;

    /* The default colours are created before the first frame exists so check
     * that there is a frame before invalidating the caches */
    if(frameCur != NULL)
    {
        meFrameData *fd ;

        meFrameLoopBegin() ;

        meFrameLoopContinue(loopFrame->flags & meFRAME_HIDDEN) ;

        if((fd = (meFrameData *) loopFrame->termData) != NULL)
        {
            /* The colour has been redefined so whatever the canvas holds is
             * out of date */
            if(fd->cgcol == index)
                fd->cgcol = meCOLOR_INVALID ;
        }
        meFrameLoopEnd() ;
    }
    return meTRUE ;
}

void
XTERMsetBgcol(void)
{
    meUInt col ;
    meFrameData *fd ;

    if(noColors == 0)
        return ;
    col = colTable[meStyleGetBColor(meSchemeGetStyle(globScheme))] ;

    @autoreleasepool
    {
        NSColor *bg = [NSColor colorWithSRGBRed:meColRed(col)
                                         green:meColGreen(col)
                                          blue:meColBlue(col)
                                         alpha:1.0] ;
        meFrameLoopBegin() ;

        meFrameLoopContinue(loopFrame->flags & meFRAME_HIDDEN) ;

        if((fd = (meFrameData *) loopFrame->termData) != NULL)
            [fd->window setBackgroundColor:bg] ;

        meFrameLoopEnd() ;
    }
}

/**************************************************************************
* Frame creation                                                          *
**************************************************************************/

static meFrameData *
meCocoaCreateWindow(meUShort width, meUShort depth)
{
    meFrameData *fd ;
    NSRect rect ;
    MEWindow *window ;
    MEView *view ;

    if((fd = meMalloc(sizeof(meFrameData))) == NULL)
        return NULL ;
    memset(fd,0,sizeof(meFrameData)) ;

    rect = NSMakeRect(0,0,width*mecm.fwidth,depth*mecm.fdepth) ;
    window = [[MEWindow alloc]
                 initWithContentRect:rect
                           styleMask:(NSWindowStyleMaskTitled |
                                      NSWindowStyleMaskClosable |
                                      NSWindowStyleMaskMiniaturizable |
                                      NSWindowStyleMaskResizable)
                             backing:NSBackingStoreBuffered
                               defer:NO] ;
    if(window == nil)
    {
        meFree(fd) ;
        return NULL ;
    }
    [window setDelegate:window] ;
    [window setReleasedWhenClosed:NO] ;
    [window setAcceptsMouseMovedEvents:YES] ;
    [window setTitle:[NSString stringWithUTF8String:meName]] ;
    [window setContentResizeIncrements:NSMakeSize(mecm.fwidth,mecm.fdepth)] ;
    [window setContentMinSize:NSMakeSize(mecm.fwidth*10,mecm.fdepth*4)] ;
    [window setCollectionBehavior:[window collectionBehavior] |
                                  NSWindowCollectionBehaviorFullScreenPrimary] ;

    view = [[MEView alloc] initWithFrame:rect] ;
    [view setAutoresizingMask:NSViewWidthSizable|NSViewHeightSizable] ;
#ifdef _DRAGNDROP
    [view registerForDraggedTypes:@[NSPasteboardTypeFileURL]] ;
#endif
    [window setContentView:view] ;
    [window makeFirstResponder:view] ;
    [view release] ;                    /* The window owns it now */

    {
        NSEdgeInsets insets = meCocoaSafeAreaInsets(view) ;

        if((insets.top > 0.0) || (insets.bottom > 0.0) ||
           (insets.left > 0.0) || (insets.right > 0.0))
            [window setContentSize:meCocoaOutsetSize(rect.size,insets)] ;
    }

    if(meWindowCount++ == 0)
        [window center] ;
    else
        [window cascadeTopLeftFromPoint:NSMakePoint(20,20)] ;

    fd->window = window ;
    fd->view = view ;
    fd->fcol = meCOLOR_FDEFAULT ;
    fd->bcol = meCOLOR_BDEFAULT ;
    fd->cgcol = meCOLOR_INVALID ;
    fd->scale = 0.0 ;

    [window makeKeyAndOrderFront:nil] ;

    return fd ;
}

int
meFrameXTermInit(meFrame *frame, meFrame *sibling)
{
    if(sibling == NULL)
    {
        meFrameData *fd ;

#if MEOPT_MWFRAME
        if(firstFrameData != NULL)
        {
            /* first call, we have already created the first window in
             * XTERMstart - use that */
            frame->termData = firstFrameData ;
            firstFrameData = NULL ;
        }
        /* An external frame, a new window is required */
        else if((frame->termData = meCocoaCreateWindow(frame->width,frame->depth+1)) == NULL)
            return meFALSE ;
#else
        frame->termData = firstFrameData ;
        firstFrameData = NULL ;
#endif
        if((fd = (meFrameData *) frame->termData) == NULL)
            return meFALSE ;

        [fd->window meSetFrame:frame] ;
        [fd->view meSetFrame:frame] ;

        /* The window server may have trimmed the window to fit the screen
         * before the frame was attached to it, so the editors idea of the
         * size is the one that wins here */
        meFrameSetWindowSize(frame) ;
        meCocoaFrameCanvasCreate(frame) ;

        if([fd->window isKeyWindow])
            frame->flags &= ~meFRAME_NOT_FOCUS ;
        else
            frame->flags |= meFRAME_NOT_FOCUS ;
    }
    else
        /* internal frame, just share the window */
        frame->termData = sibling->termData ;
    return meTRUE ;
}

void
meFrameXTermFree(meFrame *frame, meFrame *sibling)
{
    if(sibling == NULL)
    {
        meFrameData *fd = (meFrameData *) frame->termData ;

        if(fd != NULL)
        {
            [fd->window setDelegate:nil] ;
            [fd->view meSetFrame:NULL] ;
            [fd->window meSetFrame:NULL] ;
            [fd->window orderOut:nil] ;
            [fd->window close] ;
            [fd->window release] ;
            meCocoaFrameCanvasFree(fd) ;
            meFree(fd) ;
        }
        frame->termData = NULL ;
    }
}

void
meFrameXTermMakeCur(meFrame *frame)
{
    meFrameData *fd = (meFrameData *) frame->termData ;

    if(fd != NULL)
        [fd->window makeKeyAndOrderFront:nil] ;
}

/*
 * meFrameSetWindowSize
 * Resize the width & depth of the frame window. If the resize has been
 * disabled (within windowDidResize:) then do not modify the window size -
 * that operation is performed elsewhere.
 */
void
meFrameSetWindowSize(meFrame *frame)
{
    meFrameData *fd ;

    if(
#ifdef _ME_CONSOLE
       !(meSystemCfg & meSYSTEM_CONSOLE) &&
#endif /* _ME_CONSOLE */
       (disableResize == 0) &&
       ((fd = (meFrameData *) frame->termData) != NULL) &&
       ![fd->window isZoomed] &&
       !([fd->window styleMask] & NSWindowStyleMaskFullScreen))
    {
        NSSize sz = meCocoaOutsetSize(
                        NSMakeSize(mecm.fwidth*frame->width,
                                   mecm.fdepth*(frame->depth+1)),
                        meCocoaSafeAreaInsets([fd->window contentView])) ;
        NSSize cur = [[fd->window contentView] frame].size ;

        if((((int) cur.width) != ((int) sz.width)) ||
           (((int) cur.height) != ((int) sz.height)))
            [fd->window setContentSize:sz] ;
    }
}

#if MEOPT_EXTENDED
void
meFrameRepositionWindow(meFrame *frame, int resize)
{
#ifdef _ME_CONSOLE
    if(meSystemCfg & meSYSTEM_CONSOLE)
        return ;
#endif /* _ME_CONSOLE */
    {
        meFrameData *fd = (meFrameData *) frame->termData ;
        NSRect screen, wframe ;

        if((fd == NULL) || ([fd->window screen] == nil))
            return ;
        screen = [[fd->window screen] visibleFrame] ;
        wframe = [fd->window frame] ;

        if(resize)
        {
            if(wframe.size.width > screen.size.width)
                wframe.size.width = screen.size.width ;
            if(wframe.size.height > screen.size.height)
                wframe.size.height = screen.size.height ;
        }
        if((wframe.origin.x + wframe.size.width) > NSMaxX(screen))
            wframe.origin.x = NSMaxX(screen) - wframe.size.width ;
        if(wframe.origin.x < screen.origin.x)
            wframe.origin.x = screen.origin.x ;
        if((wframe.origin.y + wframe.size.height) > NSMaxY(screen))
            wframe.origin.y = NSMaxY(screen) - wframe.size.height ;
        if(wframe.origin.y < screen.origin.y)
            wframe.origin.y = screen.origin.y ;

        if(!NSEqualRects(wframe,[fd->window frame]))
            [fd->window setFrame:wframe display:YES] ;
    }
}
#endif

/*
 * meFrameSetWindowTitle
 * Put the name of the buffer into the window frame
 */
void
meFrameSetWindowTitle(meFrame *frame, meUByte *str)
{
    meFrameData *fd ;

#ifdef _ME_CONSOLE
    if(meSystemCfg & meSYSTEM_CONSOLE)
        return ;
#endif /* _ME_CONSOLE */
    if((fd = (meFrameData *) frame->termData) == NULL)
        return ;

    @autoreleasepool
    {
        char buf[meBUF_SIZE_MAX] ;
        NSString *title ;

#if MEOPT_EXTENDED
        if(frameTitle != NULL)
            meStrcpy(buf,frameTitle) ;
        else
#endif
            meStrcpy(buf,meName) ;
        if(str != NULL)
        {
            meStrcat(buf,": ") ;
            meStrcat(buf,str) ;
        }
        if((title = [NSString stringWithUTF8String:buf]) == nil)
            title = [NSString stringWithUTF8String:meName] ;
        [fd->window setTitle:title] ;
    }
}

/**************************************************************************
* Focus                                                                   *
**************************************************************************/

static void
meCocoaFrameGainFocus(meFrame *frame)
{
    if((frame == NULL) || !(frame->flags & meFRAME_NOT_FOCUS))
        return ;

    frame->flags &= ~meFRAME_NOT_FOCUS ;
#if MEOPT_MWFRAME
    if(frameCur != frame)
        frameFocus = frame ;
#endif
    if((cursorState >= 0) && blinkState)
    {
        if(cursorBlink)
            TThandleBlink(2) ;
        else
            meFrameXTermShowCursor(frame) ;
        meCocoaFlush() ;
    }
}

static void
meCocoaFrameKillFocus(meFrame *frame)
{
    if((frame == NULL) || (frame->flags & meFRAME_NOT_FOCUS))
        return ;

    frame->flags |= meFRAME_NOT_FOCUS ;
#if MEOPT_MWFRAME
    if(frameFocus == frame)
        frameFocus = NULL ;
#endif
    if(cursorState >= 0)
    {
        /* because the cursor is a part of the solid cursor we must remove the
         * old one first and then redraw */
        if(blinkState)
            meFrameXTermHideCursor(frame) ;
        blinkState = 1 ;
        meFrameXTermShowCursor(frame) ;
        meCocoaFlush() ;
    }
}

/**************************************************************************
* Keyboard                                                                *
**************************************************************************/

/*
 * meCocoaFixCharMask
 * Bytes 0x80-0xa0 are marked "not displayable" in charMaskTbl1 (they are the
 * Latin-1 C1 control range) so display.c's renderLine() expands them into a
 * literal "\xNN" escape rather than drawing them - but those same byte
 * values are also exactly the UTF-8 continuation bytes that meCocoaKeyEvent
 * relies on to store non-Latin-1 characters without losing them. Mark them
 * displayable so those bytes reach meCocoaDrawString and are drawn (one
 * glyph per byte, not combined) instead of being escaped away.
 *
 * charMaskTblInit() (bind.c) resets this table from the startup macros
 * after XTERMstart() has already run, so patching it there does not stick -
 * apply it lazily, the first time a key actually needs it, which is
 * necessarily after all startup processing has finished.
 */
static void
meCocoaFixCharMask(void)
{
    static int done = 0 ;
    int cc ;

    if(done)
        return ;
    done = 1 ;
    for(cc=0x80 ; cc<=0xa0 ; cc++)
        charMaskTbl1[cc] |= CHRMSK_DISPLAYABLE ;
}

/*
 * meCocoaKeyEvent
 * Translate an AppKit key press into an editor key and queue it. The special
 * (function) keys arrive as characters in the Unicode private use area, see
 * NSUpArrowFunctionKey and friends.
 */
static void
meCocoaKeyEvent(NSEvent *ev)
{
    meCocoaFixCharMask() ;
    NSString *chars = [ev charactersIgnoringModifiers] ;
    NSEventModifierFlags mods = [ev modifierFlags] ;
    meUShort ii ;
    unichar cc ;
    int isSpecial = 0 ;
    int isBound = 0 ;

    if((chars == nil) || ([chars length] == 0))
        return ;
    cc = [chars characterAtIndex:0] ;

    switch(cc)
    {
    case NSUpArrowFunctionKey:      ii = SKEY_up ;          isSpecial=1 ; break ;
    case NSDownArrowFunctionKey:    ii = SKEY_down ;        isSpecial=1 ; break ;
    case NSLeftArrowFunctionKey:    ii = SKEY_left ;        isSpecial=1 ; break ;
    case NSRightArrowFunctionKey:   ii = SKEY_right ;       isSpecial=1 ; break ;
    case NSF1FunctionKey:           ii = SKEY_f1 ;          isSpecial=1 ; break ;
    case NSF2FunctionKey:           ii = SKEY_f2 ;          isSpecial=1 ; break ;
    case NSF3FunctionKey:           ii = SKEY_f3 ;          isSpecial=1 ; break ;
    case NSF4FunctionKey:           ii = SKEY_f4 ;          isSpecial=1 ; break ;
    case NSF5FunctionKey:           ii = SKEY_f5 ;          isSpecial=1 ; break ;
    case NSF6FunctionKey:           ii = SKEY_f6 ;          isSpecial=1 ; break ;
    case NSF7FunctionKey:           ii = SKEY_f7 ;          isSpecial=1 ; break ;
    case NSF8FunctionKey:           ii = SKEY_f8 ;          isSpecial=1 ; break ;
    case NSF9FunctionKey:           ii = SKEY_f9 ;          isSpecial=1 ; break ;
    case NSF10FunctionKey:          ii = SKEY_f10 ;         isSpecial=1 ; break ;
    case NSF11FunctionKey:          ii = SKEY_f11 ;         isSpecial=1 ; break ;
    case NSF12FunctionKey:          ii = SKEY_f12 ;         isSpecial=1 ; break ;
    case NSInsertFunctionKey:
    case NSInsertCharFunctionKey:   ii = SKEY_insert ;      isSpecial=1 ; break ;
    case NSDeleteFunctionKey:
    case NSDeleteCharFunctionKey:   ii = SKEY_delete ;      isSpecial=1 ; break ;
    case NSHomeFunctionKey:         ii = SKEY_home ;        isSpecial=1 ; break ;
    case NSBeginFunctionKey:        ii = SKEY_home ;        isSpecial=1 ; break ;
    case NSEndFunctionKey:          ii = SKEY_end ;         isSpecial=1 ; break ;
    case NSPageUpFunctionKey:
    case NSPrevFunctionKey:         ii = SKEY_page_up ;     isSpecial=1 ; break ;
    case NSPageDownFunctionKey:
    case NSNextFunctionKey:         ii = SKEY_page_down ;   isSpecial=1 ; break ;
    case NSPrintScreenFunctionKey:
    case NSPrintFunctionKey:        ii = SKEY_print ;       isSpecial=1 ; break ;
    case NSPauseFunctionKey:        ii = SKEY_pause ;       isSpecial=1 ; break ;
    case NSSysReqFunctionKey:       ii = SKEY_sys_req ;     isSpecial=1 ; break ;
    case NSBreakFunctionKey:        ii = SKEY_break ;       isSpecial=1 ; break ;
    case NSSelectFunctionKey:       ii = SKEY_select ;      isSpecial=1 ; break ;
    case NSExecuteFunctionKey:      ii = SKEY_execute ;     isSpecial=1 ; break ;
    case NSUndoFunctionKey:         ii = SKEY_undo ;        isSpecial=1 ; break ;
    case NSRedoFunctionKey:         ii = SKEY_redo ;        isSpecial=1 ; break ;
    case NSFindFunctionKey:         ii = SKEY_find ;        isSpecial=1 ; break ;
    case NSHelpFunctionKey:         ii = SKEY_help ;        isSpecial=1 ; break ;
    case NSMenuFunctionKey:         ii = SKEY_menu ;        isSpecial=1 ; break ;
    case NSClearLineFunctionKey:    ii = SKEY_clear ;       isSpecial=1 ; break ;
    case NSScrollLockFunctionKey:   ii = SKEY_scroll_lock ; isSpecial=1 ; isBound=1 ; break ;

    case 0x0d:                      /* Return */
    case 0x03:                      /* Enter (keypad) */
        ii = SKEY_return ;          isSpecial=1 ; break ;
    case 0x09:                      /* Tab */
        ii = SKEY_tab ;             isSpecial=1 ; break ;
    case 0x19:                      /* Back tab - shift is implied */
        ii = SKEY_tab ;             isSpecial=1 ;
        mods |= NSEventModifierFlagShift ;
        break ;
    case 0x0a:                      /* Line feed */
        ii = SKEY_linefeed ;        isSpecial=1 ; break ;
    case 0x1b:                      /* Escape */
        ii = SKEY_esc ;             isSpecial=1 ; break ;
    case 0x7f:                      /* Backspace, the macOS delete key */
        ii = SKEY_backspace ;       isSpecial=1 ; break ;

    default:
        if((cc >= 0xf700) && (cc <= 0xf8ff))
            /* An unhandled function key - throw it away rather than inserting
             * a private use area character into the buffer */
            return ;
        if(cc > 0xff)
        {
            /* The editor buffer is byte oriented, it has no concept of a
             * multi-byte character. Rather than downcast to Latin-1 (which
             * silently destroys anything outside that range - Cyrillic,
             * CJK, combining marks, ...) encode what was actually typed as
             * UTF-8 and feed the bytes through as ordinary characters. The
             * bytes round-trip correctly through the buffer and on to disk;
             * on screen each byte still occupies its own cell (the fixed
             * one-glyph-per-byte renderer has no decoder), but the text
             * itself is no longer lost or corrupted. */
            NSString *typed = [ev characters] ;

            if((typed != nil) && ([typed length] > 0) &&
               !(mods & (NSEventModifierFlagControl|NSEventModifierFlagCommand)))
            {
                NSData *data = [typed dataUsingEncoding:NSUTF8StringEncoding] ;
                const meUByte *bp = (const meUByte *) [data bytes] ;
                NSUInteger len = [data length], jj ;

                for(jj=0 ; jj<len ; jj++)
                    addKeyToBuffer((meUShort) bp[jj]) ;
            }
            return ;
        }
        ii = (meUShort) cc ;
        break ;
    }

    if(isSpecial)
    {
        ii |= ME_SPECIAL ;
        /* Only add the shift mask if it is special */
        if(mods & NSEventModifierFlagShift)
            ii |= ME_SHIFT ;
        if(mods & NSEventModifierFlagControl)
            ii |= ME_CONTROL ;
        if(mods & NSEventModifierFlagOption)
            ii |= ME_ALT ;

        if(isBound)
        {
            /* Keys that are only reported if the user has bound them */
            meUInt arg ;
            if(decode_key(ii,&arg) == -1)
                return ;
        }
    }
    else if(mods & (NSEventModifierFlagControl|NSEventModifierFlagOption))
    {
        /* Control and alt characters are canonicalised in the same way as the
         * Xlib back-end does, C-a and C-A are the same key */
        meUShort kk = toUpper(ii) ;

        if(!(mods & NSEventModifierFlagControl) || (kk < 'A') || (kk > '_'))
        {
            ii = toLower(kk) ;
            if(mods & NSEventModifierFlagControl)
                ii |= ME_CONTROL ;
        }
        else
            ii = kk - '@' ;
        if(mods & NSEventModifierFlagOption)
            ii |= ME_ALT ;
    }
    else
    {
        /* A plain character - take what the keyboard layout produced so that
         * the option based accented characters work */
        NSString *typed = [ev characters] ;

        if((typed != nil) && ([typed length] > 0))
        {
            unichar tc = [typed characterAtIndex:0] ;
            if((tc >= 0x20) && (tc <= 0xff))
                ii = (meUShort) tc ;
        }
    }
    addKeyToBuffer(ii) ;
}

/**************************************************************************
* Mouse                                                                   *
**************************************************************************/
#if MEOPT_MOUSE

/*
 * meCocoaMouseKeyState
 * Convert the AppKit modifier flags into the editors mouse key state.
 */
static meUShort
meCocoaMouseKeyState(NSEventModifierFlags mods)
{
    meUShort ss = 0 ;

    if(mods & NSEventModifierFlagShift)
        ss |= ME_SHIFT ;
    if(mods & NSEventModifierFlagControl)
        ss |= ME_CONTROL ;
    if(mods & NSEventModifierFlagOption)
        ss |= ME_ALT ;
    return ss ;
}

/*
 * meCocoaMouseButton
 * Map an AppKit button number onto an X style button number - 1 is left,
 * 2 middle and 3 right - so that the existing mouse translation applies.
 */
static int
meCocoaMouseButton(NSEvent *ev)
{
    switch([ev buttonNumber])
    {
    case 0:  return 1 ;
    case 1:  return 3 ;
    case 2:  return 2 ;
    case 3:  return 4 ;
    default: return 5 ;
    }
}

/*
 * meCocoaMouseEvent
 * Common handling for all of the mouse events. 'type' is 0 for a move, 1 for
 * a button press, 2 for a button release and 3 for the scroll wheel.
 */
static void
meCocoaMouseEvent(meFrame *frame, NSEvent *ev, int type)
{
    meFrameData *fd ;
    NSPoint pt ;
    meUShort ss ;
    int xx, yy ;

    if(!(meMouseCfg & meMOUSE_ENBLE) || (frame == NULL) ||
       ((fd = (meFrameData *) frame->termData) == NULL))
        return ;

    /* Collect the position of the mouse. The editor wants the row/column and
     * the fractional part within the cell for the scroll bars. */
    pt = [fd->view convertPoint:[ev locationInWindow] fromView:nil] ;
    xx = (int) (pt.x - fd->originX) ;
    yy = (int) (pt.y - fd->originY) ;
    if(xx < 0)
        xx = 0 ;
    if(yy < 0)
        yy = 0 ;
    mouse_X = xx / mecm.fwidth ;
    mouse_Y = yy / mecm.fdepth ;
    mouse_dX = ((xx - (mouse_X * mecm.fwidth)) << 8) / mecm.fwidth ;
    mouse_dY = ((yy - (mouse_Y * mecm.fdepth)) << 8) / mecm.fdepth ;

    mouseKeyState = meCocoaMouseKeyState([ev modifierFlags]) ;

    switch(type)
    {
    case 0:                             /* Movement */
        {
            meUShort cc ;
            meUInt arg ;

            cc = (ME_SPECIAL | mouseKeyState |
                  (SKEY_mouse_move+mouseKeys[mouseButtonGetPick()])) ;
            /* Are we after all movements or is mouse-move bound ?? */
            if((TTallKeys & 0x1) || (!TTallKeys && (decode_key(cc,&arg) != -1)))
                addKeyToBufferOnce(cc) ;
        }
        break ;

    case 1:                             /* Button press */
        {
            int bb = meCocoaMouseButton(ev) ;

            if(frame->flags & meFRAME_NOT_FOCUS)
            {
                [fd->window makeKeyAndOrderFront:nil] ;
                meCocoaFrameGainFocus(frame) ;
            }
            mouseButtonPick(bb) ;
            ss = (ME_SPECIAL | (SKEY_mouse_pick_1+mouseKeys[bb]-1) | mouseKeyState) ;
            addKeyToBuffer(ss) ;
        }
        break ;

    case 2:                             /* Button release */
        {
            int bb = meCocoaMouseButton(ev) ;

            mouseButtonDrop(bb) ;
            ss = (ME_SPECIAL | (SKEY_mouse_drop_1+mouseKeys[bb]-1) | mouseKeyState) ;
            addKeyToBuffer(ss) ;
        }
        break ;

    case 3:                             /* Scroll wheel */
        {
            /* A trackpad delivers a stream of fractional deltas, accumulate
             * them so that one gesture does not turn into a flood of keys */
            static CGFloat residue = 0.0 ;
            CGFloat delta ;
            int count ;

            if([ev hasPreciseScrollingDeltas])
                delta = [ev scrollingDeltaY] / ((CGFloat) mecm.fdepth) ;
            else
                delta = [ev scrollingDeltaY] ;
            if((delta > 0.0) != (residue > 0.0))
                residue = 0.0 ;         /* Direction change, start again */
            residue += delta ;
            count = (int) ((residue < 0.0) ? -residue:residue) ;
            if(count == 0)
                break ;
            if(count > 16)
                count = 16 ;
            residue -= (residue < 0.0) ? -((CGFloat) count):((CGFloat) count) ;
            ss = ME_SPECIAL | mouseKeyState |
                 ((delta > 0.0) ? SKEY_mouse_wup:SKEY_mouse_wdown) ;
            while(--count >= 0)
                addKeyToBuffer(ss) ;
        }
        break ;
    }
}
#endif /* MEOPT_MOUSE */

/*
 * meCocoaSetMouseCursor
 * Apply one of the editors mouse cursor shapes to every frame.
 */
void
meCocoaSetMouseCursor(meUByte cursor)
{
    meFrameData *fd ;

    if(cursor == meCurCursor)
        return ;
    meCurCursor = cursor ;

    @autoreleasepool
    {
        NSCursor *cc ;

        switch(cursor)
        {
        case meCURSOR_ARROW:     cc = [NSCursor arrowCursor] ; break ;
        case meCURSOR_IBEAM:     cc = [NSCursor IBeamCursor] ; break ;
        case meCURSOR_CROSSHAIR: cc = [NSCursor crosshairCursor] ; break ;
        case meCURSOR_GRAB:      cc = [NSCursor openHandCursor] ; break ;
        case meCURSOR_WAIT:      cc = [NSCursor arrowCursor] ; break ;
        case meCURSOR_STOP:      cc = [NSCursor operationNotAllowedCursor] ; break ;
        default:                 cc = nil ; break ;
        }
        meFrameLoopBegin() ;

        meFrameLoopContinue(loopFrame->flags & meFRAME_HIDDEN) ;

        if((fd = (meFrameData *) loopFrame->termData) != NULL)
            [fd->view meSetCursor:cc] ;

        meFrameLoopEnd() ;
    }
}

/**************************************************************************
* Event pump                                                              *
**************************************************************************/

/*
 * meCocoaNextEvent
 * Fetch (and optionally dispatch) the next AppKit event, waiting until
 * 'until' at the latest. 'until' == nil polls without blocking. Shared by
 * meCocoaEventHandler(), meCocoaEventsPending() and meCocoaWaitEvent().
 */
static NSEvent *
meCocoaNextEvent(NSDate *until, BOOL dequeue)
{
    return [NSApp nextEventMatchingMask:NSEventMaskAny
                               untilDate:until
                                  inMode:NSDefaultRunLoopMode
                                 dequeue:dequeue] ;
}

/*
 * meCocoaEventHandler
 * Drain the AppKit event queue without blocking. Called from TTahead().
 */
void
meCocoaEventHandler(void)
{
    NSEvent *ev ;

    @autoreleasepool
    {
        while((ev = meCocoaNextEvent(nil,YES)) != nil)
            [NSApp sendEvent:ev] ;
    }
}

int
meCocoaEventsPending(void)
{
    int pending ;

    @autoreleasepool
    {
        pending = (meCocoaNextEvent(nil,NO) != nil) ;
    }
    return pending ;
}

/*
 * meCocoaWaitEvent
 * Sleep in the AppKit event loop for at most 'msec' milliseconds, dispatching
 * the event that wakes us. Called from waitForEvent().
 */
void
meCocoaWaitEvent(int msec)
{
    NSEvent *ev ;

    @autoreleasepool
    {
        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:
                                    ((NSTimeInterval) msec) / 1000.0] ;

        if((ev = meCocoaNextEvent(until,YES)) != nil)
            [NSApp sendEvent:ev] ;
    }
}

/**************************************************************************
* Clipboard                                                               *
**************************************************************************/
#ifdef _CLIPBRD

/*
 * TTsetClipboard
 * Offer the kill buffer to the rest of the system. The data itself is only
 * generated if something asks for it, see -pasteboard:provideDataForType:.
 */
void
TTsetClipboard(void)
{
    if(!(meSystemCfg & (meSYSTEM_CONSOLE|meSYSTEM_NOCLIPBRD)) &&
       !(clipState & CLIP_DISABLED) && (kbdmode != mePLAY))
    {
        @autoreleasepool
        {
            NSPasteboard *pb = [NSPasteboard generalPasteboard] ;

            [pb clearContents] ;
            meClipChangeCount = [pb declareTypes:@[NSPasteboardTypeString]
                                          owner:meAppDelegate] ;
            clipState |= CLIP_OWNER ;
            clipState &= ~CLIP_STALE ;
        }
    }
}

/*
 * TTgetClipboard
 * Pull the contents of the system pasteboard into the kill buffer ready for a
 * yank. If we still own the pasteboard then our kill buffer is already the
 * most recent copy and there is nothing to do.
 */
void
TTgetClipboard(void)
{
    if((meSystemCfg & (meSYSTEM_CONSOLE|meSYSTEM_NOCLIPBRD)) ||
       (clipState & CLIP_DISABLED) || (kbdmode == mePLAY))
        return ;

    @autoreleasepool
    {
        NSPasteboard *pb = [NSPasteboard generalPasteboard] ;
        NSString *str ;
        NSData *data ;
        const meUByte *sp ;
        meUByte *tmpbuf, *tp, *dd ;
        NSUInteger len, ii ;
        int outlen ;

        /* Has somebody else taken ownership since we last set it? */
        if([pb changeCount] != meClipChangeCount)
            clipState &= ~CLIP_OWNER ;
        if(clipState & CLIP_OWNER)
            return ;

        if((str = [pb stringForType:NSPasteboardTypeString]) == nil)
            return ;
        if((data = [str dataUsingEncoding:NSISOLatin1StringEncoding
                     allowLossyConversion:YES]) == nil)
            return ;
        len = [data length] ;
        sp = (const meUByte *) [data bytes] ;

        if((tmpbuf = meMalloc(len+1)) == NULL)
            return ;

        /* Strip the carriage returns out of any CRLF line endings */
        tp = tmpbuf ;
        for(ii=0 ; ii<len ; ii++)
        {
            if((sp[ii] == '\r') && ((ii+1) < len) && (sp[ii+1] == '\n'))
                continue ;
            if(sp[ii] == '\r')
                *tp++ = '\n' ;
            else
                *tp++ = sp[ii] ;
        }
        *tp = '\0' ;
        outlen = (int) (tp - tmpbuf) ;

        /* Make sure that it is not the same as the current kill buffer head */
        if((outlen == 0) ||
           (klhead == NULL) ||
           (klhead->kill == NULL) ||
           (klhead->kill->next != NULL) ||
           (meStrcmp(klhead->kill->data,tmpbuf)))
        {
            /* Always killSave, we don't want to glue them together. Note that
             * killSave() calls TTsetClipboard() which re-declares our
             * ownership, that is fine - we already have the data. */
            killSave() ;
            if((dd = killAddNode(outlen+1)) != NULL)
                memcpy(dd,tmpbuf,outlen+1) ;
            thisflag = meCFKILL ;
        }
        meFree(tmpbuf) ;
    }
}
#endif /* _CLIPBRD */

/**************************************************************************
* Start up                                                                *
**************************************************************************/

/*
 * meCocoaResourcePath
 * The Resources directory of the application bundle, which is where the
 * macros are installed when running as a bundled application.
 */
meUByte *
meCocoaResourcePath(void)
{
    static meUByte *path = NULL ;
    static int looked = 0 ;

    if(!looked)
    {
        looked = 1 ;
        @autoreleasepool
        {
            NSString *rp = [[NSBundle mainBundle] resourcePath] ;

            if((rp != nil) && ([rp length] > 0))
                path = meStrdup((meUByte *) [rp fileSystemRepresentation]) ;
        }
    }
    return path ;
}

/*
 * XTERMstart
 * Bring up the window system. Named for consistency with the Xlib back-end,
 * TTstart() dispatches here when we are not running on a terminal.
 */
int
XTERMstart(void)
{
    int ww, hh ;

    @autoreleasepool
    {
        NSScreen *screen ;
        NSRect visible ;

        [NSApplication sharedApplication] ;
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular] ;

        meAppDelegate = [[MEApplicationDelegate alloc] init] ;
        [NSApp setDelegate:meAppDelegate] ;

        /* Establish the font, and with it the character cell size */
        if(meCocoaSetFont(nil,meCOCOA_FONT_DEF) == meFALSE)
        {
            fprintf(stderr,"MicroEmacs: Failed to load a fixed pitch font\n") ;
            return meFALSE ;
        }

        /* The graphics characters render properly in a window, so turn on the
         * ANSI 0-31 rendering by default */
        meSystemCfg |= meSYSTEM_FONTFIX ;

        meCocoaBuildMenu() ;
        [NSApp finishLaunching] ;

        /* Work out a sensible default geometry. The window chrome has to come
         * out of the screen budget or the window server shrinks the window
         * behind our back and the editor and the window disagree on the size. */
        ww = 80 ;
        hh = 50 ;
        if((screen = [NSScreen mainScreen]) != nil)
        {
            NSRect probe = [NSWindow frameRectForContentRect:NSMakeRect(0,0,100,100)
                                                   styleMask:(NSWindowStyleMaskTitled |
                                                              NSWindowStyleMaskClosable |
                                                              NSWindowStyleMaskMiniaturizable |
                                                              NSWindowStyleMaskResizable)] ;
            CGFloat chromeW = probe.size.width - 100.0 ;
            CGFloat chromeH = probe.size.height - 100.0 ;

            visible = [screen visibleFrame] ;
            if((ww * mecm.fwidth) > (visible.size.width - chromeW))
                ww = ((int) (visible.size.width - chromeW)) / mecm.fwidth ;
            if((hh * mecm.fdepth) > (visible.size.height - chromeH))
                hh = ((int) (visible.size.height - chromeH)) / mecm.fdepth ;
        }
        if(ww < 10)
            ww = 10 ;
        if(hh < 4)
            hh = 4 ;
        TTwidthDefault = (meUShort) ww ;
        TTdepthDefault = (meUShort) hh ;

        if((firstFrameData = meCocoaCreateWindow(TTwidthDefault,TTdepthDefault)) == NULL)
            return meFALSE ;

        [NSApp activateIgnoringOtherApps:YES] ;
    }
    return meTRUE ;
}

#endif /* _COCOA */
