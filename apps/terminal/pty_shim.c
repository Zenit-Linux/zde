
#define _XOPEN_SOURCE 600
#define _DEFAULT_SOURCE

#include <pty.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

int zde_pty_spawn(const char *path, char *const argv[], char *const envp[],
                   const char *cwd, int cols, int rows, int *out_master) {
  int master = -1, slave = -1;
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_col = (unsigned short)(cols > 0 ? cols : 80);
  ws.ws_row = (unsigned short)(rows > 0 ? rows : 24);

  if (openpty(&master, &slave, NULL, NULL, &ws) == -1) {
    return -1;
  }

  pid_t pid = fork();
  if (pid < 0) {
    int e = errno;
    close(master);
    close(slave);
    errno = e;
    return -1;
  }

  if (pid == 0) {
    /* --- dziecko: staje się nową sesją i przejmuje slave jako swój
     * terminal kontrolujący, potem podmienia się execve na docelowy
     * program (zwykle /bin/bash). Błędy tutaj kończą proces przez _exit
     * (nie exit -- nie chcemy uruchamiać atexit/buforów odziedziczonych
     * po rodzicu), z kodami rozróżnialnymi od normalnego zamknięcia
     * powłoki. */
    close(master);

    if (setsid() == -1) {
      _exit(125);
    }
    if (ioctl(slave, TIOCSCTTY, 0) == -1) {
      _exit(126);
    }

    if (dup2(slave, STDIN_FILENO) == -1 ||
        dup2(slave, STDOUT_FILENO) == -1 ||
        dup2(slave, STDERR_FILENO) == -1) {
      _exit(126);
    }
    if (slave > STDERR_FILENO) {
      close(slave);
    }

    if (cwd != NULL && cwd[0] != '\0') {
      /* Celowo ignorujemy błąd chdir -- lepiej zostać w bieżącym
       * katalogu niż nie uruchomić powłoki wcale. */
      if (chdir(cwd) != 0) {
        /* brak akcji celowo */
      }
    }

    if (envp != NULL) {
      execve(path, argv, envp);
    } else {
      execv(path, argv);
    }
    /* execve wraca tylko przy błędzie */
    _exit(127);
  }

  /* --- rodzic --- */
  close(slave);
  *out_master = master;
  return (int)pid;
}

int zde_pty_resize(int master, int cols, int rows) {
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_col = (unsigned short)(cols > 0 ? cols : 80);
  ws.ws_row = (unsigned short)(rows > 0 ? rows : 24);
  return ioctl(master, TIOCSWINSZ, &ws);
}
