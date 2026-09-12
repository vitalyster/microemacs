if (APPLE)
    # macOS has a native window system (Cocoa) so the GUI is built by default
    option(ENABLE_GUI "Build GUI" ON)
else()
    option(ENABLE_GUI "Build GUI" OFF)
endif()
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
set (VTE_SRCS unixterm.c)
set (COCOA_SRCS cocoaterm.m)
if (WIN32)
    list(APPEND SRCS ${WIN32_SRCS})
    add_definitions(-D_CRT_SECURE_NO_WARNINGS)
    add_definitions(-D_UNICODE)
    add_definitions(-DUNICODE)
endif()
if (APPLE)
    add_definitions(-D_DARWIN)
endif()
if(${CMAKE_SYSTEM_NAME} STREQUAL "Linux")
    add_definitions(-D_LINUX)
    add_definitions(-D_LINUX26)
endif()
if (UNIX)
    add_definitions(-D_LARGEFILE_SOURCE)
    add_definitions(-D_FILE_OFFSET_BITS=64)
    list(APPEND SRCS ${VTE_SRCS})
endif()
if (ENABLE_GUI)
    add_definitions(-D_ME_WINDOW)
endif()
add_definitions(-D_ME_CONSOLE)

# The macOS window back-end. This replaces the Xlib code in unixterm.c, which
# is compiled out by the _COCOA/_XTERM selection in emain.h.
if (APPLE AND ENABLE_GUI)
    enable_language(OBJC)
    list(APPEND SRCS ${COCOA_SRCS})
    add_executable(me MACOSX_BUNDLE ${SRCS})
    set_target_properties(me PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/CocoaBundleInfo.plist
        OUTPUT_NAME me)
    find_library(APPKIT_LIBRARY AppKit REQUIRED)
    find_library(FOUNDATION_LIBRARY Foundation REQUIRED)
    find_library(CORETEXT_LIBRARY CoreText REQUIRED)
    find_library(COREGRAPHICS_LIBRARY CoreGraphics REQUIRED)
    target_link_libraries(me ${APPKIT_LIBRARY} ${FOUNDATION_LIBRARY}
                             ${CORETEXT_LIBRARY} ${COREGRAPHICS_LIBRARY})
    # Install the standard macros into the bundle so that a double clicked
    # application finds them - meSetupPathsAndUser() searches Contents/Resources
    add_custom_command(TARGET me POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
                ${CMAKE_CURRENT_SOURCE_DIR}/macros
                $<TARGET_BUNDLE_CONTENT_DIR:me>/Resources/macros
        COMMENT "Installing macros into the application bundle")
    if (EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/me.icns)
        add_custom_command(TARGET me POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    ${CMAKE_CURRENT_SOURCE_DIR}/me.icns
                    $<TARGET_BUNDLE_CONTENT_DIR:me>/Resources/me.icns
            COMMENT "Installing the application icon")
    endif()
else()
    add_executable(me ${SRCS})
endif()

if (UNIX)
    find_library(TERMCAP_LIBRARY NAMES tinfo termcap ncursesw ncurses cursesw curses)
    target_link_libraries(me ${TERMCAP_LIBRARY})
endif()
