#ifndef ZDE_PAM_SHIM_H
#define ZDE_PAM_SHIM_H

/* Zwraca 1 przy poprawnym uwierzytelnieniu użytkownika `username` hasłem
 * `password` przez PAM (usługa "login"), 0 w każdym innym wypadku. Patrz
 * duży komentarz w pam_shim.c o wymaganych uprawnieniach. */
int zde_pam_authenticate(const char *username, const char *password);

#endif
