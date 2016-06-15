option(ENABLE_GUI "Build GUI" OFF)
set (SRCS abbrev.c
          basic.c
          bind.c
          buffer.c
          crypt.c
          dirlist.c
          termio.c
          display.c
          eval.c
          exec.c
          file.c
          fileio.c
          frame.c
          hilight.c
          history.c
          input.c
          isearch.c
          key.c
          line.c
          macro.c
          main.c
          narrow.c
          next.c
          osd.c
          print.c
          random.c
          regex.c
          region.c
          registry.c
          search.c
          spawn.c
          spell.c
          tag.c
          time.c
          undo.c
          window.c
          word.c)

set (WIN32_SRCS winterm.c
                winprint.c
                me.rc)
if (WIN32)
    list(APPEND SRCS ${WIN32_SRCS})
    add_definitions(-D_CRT_SECURE_NO_WARNINGS)
    add_definitions(-D_UNICODE)
    add_definitions(-DUNICODE)
endif()
if (ENABLE_GUI)
    add_definitions(-D_ME_WINDOW)
endif()
add_definitions(-D_ME_CONSOLE)
add_executable(me ${SRCS})
