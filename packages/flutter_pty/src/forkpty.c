#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>
#include <termios.h>
#include <sys/ioctl.h>

pid_t pty_forkpty(
    int *master,
    int *slave,
    const struct termios *termp,
    const struct winsize *winp)
{
    int ptm = open("/dev/ptmx", O_RDWR | O_NOCTTY);

    if (ptm < 0)
    {
        return -1;
    }

    fcntl(ptm, F_SETFD, FD_CLOEXEC);

    if (grantpt(ptm) || unlockpt(ptm))
    {
        return -1;
    }

    char *devname;

    if ((devname = ptsname(ptm)) == NULL)
    {
        return -1;
    }

    int pts = open(devname, O_RDWR | O_NOCTTY);
    if (pts < 0)
    {
        return -1;
    }

    if (termp)
    {
        tcsetattr(pts, TCSAFLUSH, termp);
    }

    if (winp)
    {
        ioctl(pts, TIOCSWINSZ, winp);
    }

    pid_t pid = fork();

    if (pid < 0)
    {
        return -1;
    }

    if (pid == 0)
    {
        setsid();
        if (ioctl(pts, TIOCSCTTY, (char *)NULL) == -1)
            exit(-1);

        dup2(pts, STDIN_FILENO);
        dup2(pts, STDOUT_FILENO);
        dup2(pts, STDERR_FILENO);

        if (pts > 2)
        {
            close(pts);
        }
    }
    else
    {
        *master = ptm;
        if (slave)
        {
            *slave = pts;
        }
        else
        {
            // The child dup2'd the slave onto its own stdio; the parent has no
            // further use for it. Upstream only ever handed it back through the
            // out-param, so the NULL call in pty_create — the only caller —
            // stranded one descriptor per pty. libc's own forkpty() closes it
            // here for the same reason.
            close(pts);
        }
    }

    return pid;
}
