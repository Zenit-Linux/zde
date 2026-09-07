#include <security/pam_appl.h>
#include <string.h>
#include <stdlib.h>

static const char *g_password = NULL;

static int zde_pam_conv(int num_msg, const struct pam_message **msg,
                         struct pam_response **resp, void *appdata_ptr) {
  struct pam_response *responses = calloc((size_t)num_msg, sizeof(struct pam_response));
  if (responses == NULL) return PAM_BUF_ERR;

  for (int i = 0; i < num_msg; i++) {
    responses[i].resp = NULL;
    responses[i].resp_retcode = 0;
    if (msg[i]->msg_style == PAM_PROMPT_ECHO_OFF ||
        msg[i]->msg_style == PAM_PROMPT_ECHO_ON) {
      responses[i].resp = strdup(g_password != NULL ? g_password : "");
    }
  }
  *resp = responses;
  return PAM_SUCCESS;
}

/* Zwraca 1 przy poprawnym uwierzytelnieniu, 0 w każdym innym wypadku
 * (złe hasło, brak uprawnień PAM, konto zablokowane, itd. -- celowo bez
 * rozróżniania powodu w API, żeby nie ujawniać atakującemu, DLACZEGO się
 * nie udało; ta sama zasada co w prawdziwych logowaniach). */
int zde_pam_authenticate(const char *username, const char *password) {
  pam_handle_t *pamh = NULL;
  struct pam_conv conv;
  conv.conv = zde_pam_conv;
  conv.appdata_ptr = NULL;

  g_password = password;

  int status = pam_start("login", username, &conv, &pamh);
  if (status != PAM_SUCCESS) {
    g_password = NULL;
    return 0;
  }

  status = pam_authenticate(pamh, 0);
  int ok = (status == PAM_SUCCESS) ? 1 : 0;

  if (ok) {
    /* pam_acct_mgmt sprawdza dodatkowo np. czy konto nie wygasło /
     * nie jest zablokowane -- pominięcie tego to częsty błąd w prostych
     * implementacjach ekranów blokady. */
    status = pam_acct_mgmt(pamh, 0);
    ok = (status == PAM_SUCCESS) ? 1 : 0;
  }

  pam_end(pamh, status);
  g_password = NULL;
  return ok;
}
