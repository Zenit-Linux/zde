#ifndef ZDE_PTY_SHIM_H
#define ZDE_PTY_SHIM_H

/* Tworzy nowy pseudoterminal (openpty), forkuje i w dziecku ustawia go
 * jako terminal kontrolujący (setsid + TIOCSCTTY) zanim wykona execve.
 * `argv`/`envp` w stylu execve (NULL-terminated). `cwd` może być NULL/""
 * (wtedy zostaje w bieżącym katalogu procesu-rodzica). `cols`/`rows` to
 * początkowy rozmiar terminala w znakach.
 *
 * Zwraca PID dziecka (>0) i ustawia *out_master na deskryptor masterowej
 * strony pty (do czytania/pisania przez rodzica), albo -1 przy błędzie
 * (out_master niezmienione). */
int zde_pty_spawn(const char *path, char *const argv[], char *const envp[],
                   const char *cwd, int cols, int rows, int *out_master);

/* Powiadamia stronę slave (przez masterowy fd) o zmianie rozmiaru terminala
 * -- jądro samo wysyła SIGWINCH do grupy procesów terminala. Zwraca 0 przy
 * sukcesie, -1 przy błędzie (patrz errno). */
int zde_pty_resize(int master, int cols, int rows);

#endif
