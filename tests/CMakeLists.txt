# pty-driven regression tests for the UTF-8 TCAP work (see test_utf8_tcap.c).
# POSIX-only: forkpty()/<pty.h> aren't available on Windows.

add_executable(test_utf8_tcap test_utf8_tcap.c)
if (NOT APPLE)
    # forkpty() lives in libutil on Linux; it's part of libc on macOS/BSD.
    target_link_libraries(test_utf8_tcap util)
endif()

add_test(NAME utf8_tcap_display COMMAND test_utf8_tcap $<TARGET_FILE:me>)
