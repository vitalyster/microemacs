/*
 * Regression tests for UTF-8 aware editing in the TCAP (terminal) backend.
 *
 * Drives a real `me` binary through a pty and checks the escape-sequence
 * output it writes back, the same way a terminal emulator would consume
 * it. This is the only realistic way to test this: the bug class these
 * guard against (disLineColOff / column-vs-byte-offset confusion in
 * display.c) only shows up in what actually gets painted to the
 * terminal, not in any in-process data structure.
 *
 * Build:
 *   cc -o test_utf8_tcap tests/test_utf8_tcap.c -lutil   (Linux)
 *   cc -o test_utf8_tcap tests/test_utf8_tcap.c          (macOS/BSD)
 *
 * Usage:
 *   ./test_utf8_tcap [path-to-me-binary]
 *
 * Defaults to ../src/me relative to the current directory. Requires a
 * POSIX pty (Linux/macOS). Exits non-zero if any test fails.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <termios.h>
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__)
#include <util.h>
#else
#include <pty.h>
#endif

/* привет, as a byte-escaped UTF-8 literal so this file stays plain ASCII */
#define PRIVET "\xd0\xbf\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82"
/* café, likewise (c-a-f-e-with-acute) */
#define CAFE "caf\xc3\xa9"
/* a Ж b З c: 5 characters, 7 bytes */
#define MIXED_WORD "a\xd0\x96" "b\xd0\x97" "c"

static char g_binary[4096];

/* How long read_available() waits after the last byte before deciding a
 * burst of output is over. This is all local pty I/O - output shows up
 * in milliseconds - so this only needs to be comfortably above that, not
 * a full second; it directly multiplies the suite's wall-clock time since
 * every read waits it out once nothing more arrives. */
#define TAIL_TIMEOUT 0.15

/* ---- growable output buffer ------------------------------------------ */

typedef struct {
    char *data;
    size_t len;
    size_t cap;
} Buf;

static void buf_init(Buf *b)
{
    b->cap = 4096;
    b->data = malloc(b->cap);
    b->data[0] = '\0';
    b->len = 0;
}

static void buf_append(Buf *b, const char *p, size_t n)
{
    if (n == 0)
        return;
    if (b->len + n + 1 > b->cap) {
        while (b->len + n + 1 > b->cap)
            b->cap *= 2;
        b->data = realloc(b->data, b->cap);
    }
    memcpy(b->data + b->len, p, n);
    b->len += n;
    b->data[b->len] = '\0';
}

static void buf_free(Buf *b)
{
    free(b->data);
    b->data = NULL;
    b->len = b->cap = 0;
}

static int buf_contains(const Buf *b, const char *needle)
{
    return b->data != NULL && strstr(b->data, needle) != NULL;
}

/* ---- pty session ------------------------------------------------------ */

typedef struct {
    pid_t pid;
    int fd;
    char path[300];
    char dir[280];
    Buf initial; /* the startup screen redraw, for tests that need it */
} Session;

static void sleep_ms(int ms)
{
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long) (ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

static void read_available(int fd, Buf *out, double timeout_s)
{
    for (;;) {
        fd_set rfds;
        struct timeval tv;
        int rv;
        char chunk[65536];
        ssize_t n;

        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        tv.tv_sec = (long) timeout_s;
        tv.tv_usec = (long) ((timeout_s - (double) tv.tv_sec) * 1e6);

        rv = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (rv <= 0)
            return;
        n = read(fd, chunk, sizeof(chunk));
        if (n <= 0)
            return;
        buf_append(out, chunk, (size_t) n);
    }
}

/* contents may be NULL for an empty scratch file; 'name' is just the
 * filename within the scratch dir, e.g. "test.txt" or "test.c" - a few
 * of the buffer hooks (like C-mode syntax hilighting) key off the
 * extension */
static int session_open_named(Session *s, const char *contents,
                               const char *name, int cols, int rows)
{
    struct winsize ws;
    char tmpl[] = "/tmp/me-utf8-test-XXXXXX";
    char *dir = mkdtemp(tmpl);

    if (dir == NULL) {
        perror("mkdtemp");
        return -1;
    }
    strncpy(s->dir, dir, sizeof(s->dir) - 1);
    s->dir[sizeof(s->dir) - 1] = '\0';
    snprintf(s->path, sizeof(s->path), "%s/%s", s->dir, name);

    if (contents != NULL) {
        FILE *f = fopen(s->path, "w");
        if (f == NULL) {
            perror("fopen");
            return -1;
        }
        fwrite(contents, 1, strlen(contents), f);
        fclose(f);
    }

    memset(&ws, 0, sizeof(ws));
    ws.ws_row = (unsigned short) rows;
    ws.ws_col = (unsigned short) cols;

    s->pid = forkpty(&s->fd, NULL, NULL, &ws);
    if (s->pid < 0) {
        perror("forkpty");
        return -1;
    }
    if (s->pid == 0) {
        setenv("TERM", "xterm", 1);
        setenv("LANG", "en_US.UTF-8", 1);
        setenv("LC_ALL", "en_US.UTF-8", 1);
        /* $user-path (session file, "continue session" restore) defaults
         * to $HOME - without this, every run reads and rewrites the real
         * user's ~/<username>.esf, and restores whatever files earlier
         * runs (including from previous test sessions) had open, which
         * can itself trigger an autosave-recovery prompt that then eats
         * all of this test's keystrokes. Confine everything to this
         * test's own throwaway directory instead. */
        setenv("MEUSERPATH", s->dir, 1);
        /* -n forces console (TCAP) mode - on macOS the default `me` is a
         * Cocoa GUI app that never touches the controlling terminal, so
         * without this the editor just ignores the pty entirely. */
        execl(g_binary, g_binary, "-n", "-a", s->path, (char *) NULL);
        _exit(127);
    }
    sleep_ms(350);
    buf_init(&s->initial);
    read_available(s->fd, &s->initial, TAIL_TIMEOUT);
    return 0;
}

static int session_open(Session *s, const char *contents, int cols, int rows)
{
    return session_open_named(s, contents, "test.txt", cols, rows);
}

/* send raw bytes, wait, and hand back just the newly produced output */
static void session_send(Session *s, const char *data, size_t len,
                          int wait_ms, Buf *reply_out)
{
    ssize_t written = write(s->fd, data, len);
    (void) written;
    sleep_ms(wait_ms);
    buf_init(reply_out);
    read_available(s->fd, reply_out, TAIL_TIMEOUT);
}

/* Returns 1 if the child had already died on its own (crashed or exited)
 * before we force-killed it, 0 if it was still running normally. */
static int session_close(Session *s)
{
    char esc = 27;
    Buf tmp;
    int status;
    int already_dead = 0;

    buf_free(&s->initial);
    write(s->fd, &esc, 1);
    sleep_ms(200);
    buf_init(&tmp);
    read_available(s->fd, &tmp, TAIL_TIMEOUT);
    buf_free(&tmp);

    close(s->fd);
    if (waitpid(s->pid, &status, WNOHANG) == s->pid) {
        already_dead = 1;
        if (WIFSIGNALED(status))
            fprintf(stderr, "warning: me (pid %d) was killed by signal %d\n",
                    (int) s->pid, WTERMSIG(status));
        else if (WIFEXITED(status) && WEXITSTATUS(status) != 0)
            fprintf(stderr, "warning: me (pid %d) exited with status %d\n",
                    (int) s->pid, WEXITSTATUS(status));
    } else {
        kill(s->pid, SIGKILL);
        waitpid(s->pid, NULL, 0);
    }

    /* best-effort cleanup; a leaked temp dir on failure isn't worth
     * pulling in more code to guard against */
    {
        char cmd[600];
        snprintf(cmd, sizeof(cmd), "rm -rf '%s'", s->dir);
        if (system(cmd) != 0) { /* ignore */ }
    }
    return already_dead;
}

/* ---- tests -------------------------------------------------------------
 *
 * Each test returns 1 on success, 0 on failure (with failmsg filled in).
 */

static char failmsg[2048];

#define CHECK(cond, ...) \
    do { if (!(cond)) { snprintf(failmsg, sizeof(failmsg), __VA_ARGS__); return 0; } } while (0)

/* One left-arrow moves over a whole 2-byte character, not one byte. */
static int test_basic_insert_and_cursor(void)
{
    Session s;
    Buf reply;

    session_open(&s, NULL, 80, 24);
    session_send(&s, CAFE, strlen(CAFE), 150, &reply);
    buf_free(&reply);
    session_send(&s, "\x1b[D", 3, 150, &reply);   /* Left */
    buf_free(&reply);
    session_send(&s, "X", 1, 150, &reply);

    CHECK(buf_contains(&reply, "cafX\xc3\xa9"),
          "expected 'cafXe-acute' after one Left+insert, got: %.200s",
          reply.data ? reply.data : "");

    buf_free(&reply);
    session_close(&s);
    return 1;
}

/* N left-arrows over N mixed ASCII/multi-byte chars reaches column 0. */
static int test_mixed_ascii_multibyte_cursor(void)
{
    Session s;
    Buf reply;
    int i;

    session_open(&s, NULL, 80, 24);
    session_send(&s, MIXED_WORD, strlen(MIXED_WORD), 150, &reply);
    buf_free(&reply);
    for (i = 0; i < 5; i++) {
        session_send(&s, "\x1b[D", 3, 60, &reply);
        buf_free(&reply);
    }
    session_send(&s, "Y", 1, 150, &reply);

    CHECK(buf_contains(&reply, "Y" MIXED_WORD),
          "expected 'Y%s' after 5x Left+insert, got: %.200s",
          MIXED_WORD, reply.data ? reply.data : "");

    buf_free(&reply);
    session_close(&s);
    return 1;
}

static char *build_privet_line(int repeats)
{
    /* "privet privet ... privet" (space-joined, no trailing space) */
    size_t word_len = strlen(PRIVET);
    size_t total = (word_len + 1) * (size_t) repeats + 1;
    char *out = malloc(total);
    int i;

    out[0] = '\0';
    for (i = 0; i < repeats; i++) {
        strcat(out, PRIVET);
        if (i != repeats - 1)
            strcat(out, " ");
    }
    return out;
}

/* A long multi-byte line truncated at the right edge stays valid UTF-8. */
static int test_long_line_truncation(void)
{
    Session s;
    char *line = build_privet_line(10);
    char *contents = malloc(strlen(line) + 2);
    char expect[256];

    sprintf(contents, "%s\n", line);
    snprintf(expect, sizeof(expect), "%s %s %s %s %s$",
             PRIVET, PRIVET, PRIVET, PRIVET, "\xd0\xbf");

    session_open(&s, contents, 30, 10);

    CHECK(buf_contains(&s.initial, expect),
          "expected clean truncated Cyrillic text ending in $, got tail: %.300s",
          s.initial.data
              ? s.initial.data + (s.initial.len > 300 ? s.initial.len - 300 : 0)
              : "");
    CHECK(!buf_contains(&s.initial, "\xef\xbf\xbd"), /* U+FFFD replacement char */
          "replacement character found - corrupted UTF-8: %.300s",
          s.initial.data ? s.initial.data : "");

    session_close(&s);
    free(line);
    free(contents);
    return 1;
}

/* Scrolling to the end of a long multi-byte line stays valid UTF-8. */
static int test_long_line_horizontal_scroll(void)
{
    Session s;
    char *line = build_privet_line(10);
    char *contents = malloc(strlen(line) + 2);
    char expect[64];
    Buf reply;

    sprintf(contents, "%s\n", line);
    snprintf(expect, sizeof(expect), "$%s", PRIVET);

    session_open(&s, contents, 30, 10);
    session_send(&s, "\x05", 1, 150, &reply);  /* Ctrl-E: end-of-line */

    CHECK(buf_contains(&reply, expect),
          "expected scrolled view starting '$privet', got: %.300s",
          reply.data ? reply.data : "");
    CHECK(!buf_contains(&reply, "\xef\xbf\xbd"),
          "replacement character found - corrupted UTF-8: %.300s",
          reply.data ? reply.data : "");

    buf_free(&reply);
    session_close(&s);
    free(line);
    free(contents);
    return 1;
}

/* Tab stops still line up correctly around multi-byte characters. */
static int test_tabs_with_multibyte(void)
{
    Session s;
    Buf reply;

    session_open(&s, NULL, 80, 24);
    {
        static const char input[] = "a\t\xd0\x96\tb"; /* a <tab> Ж <tab> b */
        session_send(&s, input, sizeof(input) - 1, 150, &reply);
    }

    CHECK(buf_contains(&reply, "a   \xd0\x96   b"),
          "expected tab-aligned 'a   Zh   b', got: %.300s",
          reply.data ? reply.data : "");

    buf_free(&reply);
    session_close(&s);
    return 1;
}

/*
 * Syntax-hilighted buffers take a separate, still byte-per-column code
 * path (hilight.c) that this change deliberately left untouched. This
 * only checks it still runs cleanly on UTF-8 input - not that its
 * (known-imperfect) rendering of non-ASCII text is correct.
 */
static int test_syntax_hilight_does_not_crash(void)
{
    Session s;
    Buf reply;
    char contents[512];

    snprintf(contents, sizeof(contents),
             "// %s %s %s %s %s %s %s %s %s %s\nint main(void) { return 0; }\n",
             PRIVET, PRIVET, PRIVET, PRIVET, PRIVET,
             PRIVET, PRIVET, PRIVET, PRIVET, PRIVET);

    /* a .c name so the C-mode hilighting hook attaches to this buffer */
    session_open_named(&s, contents, "test.c", 30, 10);

    CHECK(buf_contains(&s.initial, "int main"),
          "editor did not render the C file at all: %.300s",
          s.initial.data ? s.initial.data : "");

    session_send(&s, "\x05", 1, 150, &reply);  /* Ctrl-E: end-of-line - still
                                                 * shouldn't crash on the
                                                 * hilighted comment line */
    buf_free(&reply);
    CHECK(!session_close(&s),
          "me crashed or exited on its own while handling this buffer");
    return 1;
}

/* ---- driver ------------------------------------------------------------ */

typedef struct {
    const char *name;
    int (*fn)(void);
} Test;

static const Test TESTS[] = {
    { "test_basic_insert_and_cursor", test_basic_insert_and_cursor },
    { "test_mixed_ascii_multibyte_cursor", test_mixed_ascii_multibyte_cursor },
    { "test_long_line_truncation", test_long_line_truncation },
    { "test_long_line_horizontal_scroll", test_long_line_horizontal_scroll },
    { "test_tabs_with_multibyte", test_tabs_with_multibyte },
    { "test_syntax_hilight_does_not_crash", test_syntax_hilight_does_not_crash },
};

int main(int argc, char **argv)
{
    size_t i;
    int failures = 0;
    size_t n = sizeof(TESTS) / sizeof(TESTS[0]);

    if (argc > 1) {
        strncpy(g_binary, argv[1], sizeof(g_binary) - 1);
    } else {
        snprintf(g_binary, sizeof(g_binary), "%s", "src/me");
    }
    if (access(g_binary, X_OK) != 0) {
        fprintf(stderr, "me binary not found or not executable at %s "
                        "- build it first (see build.txt)\n", g_binary);
        return 1;
    }

    for (i = 0; i < n; i++) {
        failmsg[0] = '\0';
        if (TESTS[i].fn()) {
            printf("PASS  %s\n", TESTS[i].name);
        } else {
            printf("FAIL  %s: %s\n", TESTS[i].name, failmsg);
            failures++;
        }
    }

    printf("\n");
    if (failures) {
        printf("%d/%zu tests failed\n", failures, n);
        return 1;
    }
    printf("All %zu tests passed\n", n);
    return 0;
}
