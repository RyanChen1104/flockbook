// Demo agent stub for scripts/demo-seed.sh. It never runs a model.
// Installed as claude, codex and pi, so herdr detects it as that agent by process name, and as demo-agent,
// which herdr does not detect (the seed script then reports the agent state itself).
// usage: <name> SCREEN [SCRIPT]
// Prints SCREEN (raw bytes; it may set the title with OSC 0) twice, 1.5 s apart, then waits for keys until the pane closes.
// Keys are not echoed. Without SCRIPT, keys are ignored.
//
// SCRIPT makes the pane answer keys (a permission prompt or a question picker). It is a list of blocks:
//   @ <state> <key>        the block runs when <key> arrives in <state>; the first state is "start"
//   show <file>            print a screen file
//   append <src> <dst>     append src to dst, with every @@NOW@@ replaced by the current UTC time (ISO 8601)
//   sleep <seconds>        decimal seconds
//   hold <file>            keep <file> open for reading
//   state <name>           the state after this block (default: unchanged)
// Keys: a printable character, or ENTER, ESC, UP, DOWN, TAB. Keys that arrive while a block runs are dropped.
// A block for key INIT in state start runs once, before any key is read.
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static void cat(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return;
    char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) fwrite(buf, 1, n, stdout);
    fclose(f);
    fflush(stdout);
}

static void append(const char *src, const char *dst) {
    FILE *in = fopen(src, "rb");
    if (!in) return;
    static char buf[1 << 20];
    size_t n = fread(buf, 1, sizeof buf - 1, in);
    fclose(in);
    buf[n] = 0;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    gmtime_r(&tv.tv_sec, &tm);
    char now[32];
    snprintf(now, sizeof now, "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
             tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000));
    FILE *out = fopen(dst, "ab");
    if (!out) return;
    const char *tok = "@@NOW@@", *p = buf, *q;
    while ((q = strstr(p, tok))) {
        fwrite(p, 1, q - p, out);
        fputs(now, out);
        p = q + strlen(tok);
    }
    fputs(p, out);
    fclose(out);
}

// Reads one key; returns its name in out ("1", "ENTER", "ESC", ...). Returns 0 on EOF.
static int read_key(char *out, size_t size) {
    unsigned char c;
    if (read(STDIN_FILENO, &c, 1) != 1) return 0;
    if (c == '\r' || c == '\n') snprintf(out, size, "ENTER");
    else if (c == '\t') snprintf(out, size, "TAB");
    else if (c == 0x1b) {
        struct pollfd p = {STDIN_FILENO, POLLIN, 0};
        unsigned char seq[2];
        if (poll(&p, 1, 40) > 0 && read(STDIN_FILENO, &seq[0], 1) == 1 && (seq[0] == '[' || seq[0] == 'O') &&
            read(STDIN_FILENO, &seq[1], 1) == 1)
            snprintf(out, size, seq[1] == 'A' ? "UP" : seq[1] == 'B' ? "DOWN" : "OTHER");
        else snprintf(out, size, "ESC");
    } else snprintf(out, size, "%c", c);
    return 1;
}

static void drain(void) {
    struct pollfd p = {STDIN_FILENO, POLLIN, 0};
    unsigned char buf[256];
    while (poll(&p, 1, 0) > 0 && read(STDIN_FILENO, buf, sizeof buf) > 0) {}
}

// Runs the block for (state, key). Returns 1 if a block matched.
static int run(const char *script, char *state, const char *key) {
    FILE *f = fopen(script, "r");
    if (!f) return 0;
    char line[4096], a[2048], b[2048];
    int in = 0, matched = 0;
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\n")] = 0;
        if (line[0] == '@') {
            if (in) break;
            in = sscanf(line, "@ %2047s %2047s", a, b) == 2 && !strcmp(a, state) && !strcmp(b, key);
            matched |= in;
        } else if (!in) continue;
        else if (sscanf(line, "show %2047s", a) == 1) cat(a);
        else if (sscanf(line, "append %2047s %2047s", a, b) == 2) append(a, b);
        else if (sscanf(line, "hold %2047s", a) == 1) { if (fopen(a, "r") == NULL) {} }
        else if (sscanf(line, "sleep %2047s", a) == 1) usleep((useconds_t)(atof(a) * 1e6));
        else if (sscanf(line, "state %63s", a) == 1) snprintf(state, 64, "%s", a);
    }
    fclose(f);
    return matched;
}

int main(int argc, char **argv) {
    struct termios t;
    if (tcgetattr(STDIN_FILENO, &t) == 0) {
        t.c_lflag &= ~(ECHO | ICANON | ISIG);
        t.c_cc[VMIN] = 1;
        t.c_cc[VTIME] = 0;
        tcsetattr(STDIN_FILENO, TCSANOW, &t);
    }
    signal(SIGINT, SIG_IGN);
    if (argc > 1) {
        cat(argv[1]);
        usleep(1500000);   // draw again: herdr detects the agent on output, and the first draw can come too early
        cat(argv[1]);
    }
    if (argc < 3) for (;;) pause();
    char state[64] = "start", key[16];
    run(argv[2], state, "INIT");
    while (read_key(key, sizeof key))
        if (run(argv[2], state, key)) drain();
    for (;;) pause();
}
