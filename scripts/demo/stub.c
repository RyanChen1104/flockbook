// Demo agent stub for scripts/demo-seed.sh. It never runs a model.
// Installed as claude, codex and pi, so herdr detects it as that agent by process name, and as demo-agent,
// which herdr does not detect (the seed script then reports the agent state itself).
// usage: <name> SCREEN
// Prints SCREEN (raw bytes; it may set the title with OSC 0), then sleeps until the pane closes.
// Keys typed into the pane are not echoed.
#include <signal.h>
#include <stdio.h>
#include <termios.h>
#include <unistd.h>

int main(int argc, char **argv) {
    struct termios t;
    if (tcgetattr(STDIN_FILENO, &t) == 0) {
        t.c_lflag &= ~(ECHO | ICANON);
        tcsetattr(STDIN_FILENO, TCSANOW, &t);
    }
    signal(SIGINT, SIG_IGN);
    FILE *f = argc > 1 ? fopen(argv[1], "rb") : NULL;
    if (f) {
        char buf[8192];
        size_t n;
        while ((n = fread(buf, 1, sizeof buf, f)) > 0) fwrite(buf, 1, n, stdout);
        fclose(f);
        fflush(stdout);
    }
    for (;;) pause();
}
