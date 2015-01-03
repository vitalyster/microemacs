AC_INIT([me], [1.0], [vitalyster@gmail.com])

AC_PREREQ(2.67)
AC_CANONICAL_HOST
AM_INIT_AUTOMAKE([1.12 foreign subdir-objects])
m4_ifdef([AM_SILENT_RULES], [AM_SILENT_RULES(yes)])

AC_CONFIG_HEADERS([src/config.h])

AC_PROG_CC
AM_PROG_CC_C_O
AC_HEADER_STDC

case $host_os in
    *darwin*)
	HOST_IS=darwin
	;;
    *linux*)
	HOST_IS=linux
	;;
    *mingw*)
	HOST_IS=windows
	AC_CHECK_TOOL(RC, [windres], [no])
	if test x$RC = xno; then
	    AC_MSG_ERROR([Resource compiler not found])
	fi
	;;
    *) ;;
esac

AM_CONDITIONAL(DARWIN, test x$HOST_IS = xdarwin)
AM_CONDITIONAL(LINUX, test x$HOST_IS = xlinux)
AM_CONDITIONAL(WINDOWS, test x$HOST_IS = xwindows)



AC_OUTPUT([Makefile src/Makefile])

