bin_PROGRAMS = me

me_CPPFLAGS = -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64 -D_ME_CONSOLE

LINUX_CPPFLAGS = -D_LINUX -D_LINUX26

GUI_CPPFLAGS = -D_ME_WINDOW

me_SOURCES = abbrev.c     basic.c bind.c       buffer.c     crypt.c      dirlist.c termio.c\
    display.c \
eval.c       exec.c       file.c       fileio.c     frame.c      hilight.c    history.c    input.c      isearch.c \
key.c        line.c       macro.c      main.c       narrow.c     next.c       osd.c        print.c      random.c \
regex.c      region.c     registry.c   search.c     spawn.c      spell.c      tag.c        time.c \
undo.c       window.c     word.c

VTE_SRCS = unixterm.c

WIN32_SRCS = winterm.c winprint.c me.rc

if DARWIN
me_CPPFLAGS += -D_DARWIN
me_SOURCES += $(VTE_SRCS)
me_LDADD = -lncurses
endif

if LINUX
me_CPPFLAGS += $(LINUX_CPPFLAGS) $(GUI_CPPFLAGS)
me_SOURCES += $(VTE_SRCS)
me_LDADD = -lX11 -lncurses
endif

if WINDOWS
me_CPPFLAGS += $(GUI_CPPFLAGS)
me_SOURCES += $(WIN32_SRCS)
me_LDADD = -lgdi32 -lcomdlg32 -lwinspool
endif

.rc.o:
	@if $(AM_V_P); then set -x; else echo "  RC       $<"; fi
	$(AM_V_at)@RC@ -o $@ $<
