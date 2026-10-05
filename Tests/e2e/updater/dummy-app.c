// Stand-in for CMCR Manager in the self-update tests (Tests/e2e/suites/updater.sh).
// Built with -DVERSION="\"1.2.3\"" and optionally -DCONFIRM="\"/path\"" (confirm the start like the real app)
// and -DLAUNCHLOG="\"/path\"" (record every launch). With CONFIRM, -DSTART_DELAY=N confirms in two steps like
// the real app ("<version> <pid>", N seconds – e.g. a Keychain dialog – then "<version>") and -DSTART_CRASH
// writes only the first step and exits (a crash while starting).
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#ifdef CONFIRM
static void confirm(const char *text) {   // atomically, like Data.write(options: .atomic)
  char tmp[4096];
  snprintf(tmp, sizeof tmp, "%s.tmp-%d", CONFIRM, (int)getpid());
  FILE *f = fopen(tmp, "w");
  if (!f) return;
  fputs(text, f);
  fclose(f);
  rename(tmp, CONFIRM);
}
#endif

int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--cmcr-self-test") == 0) { puts(VERSION); return 0; }
    if (strcmp(argv[i], "--e2e-sleep") == 0) { sleep(30); return 0; }
  }
#ifdef LAUNCHLOG
  FILE *l = fopen(LAUNCHLOG, "a");
  if (l) { fprintf(l, "launched %s\n", VERSION); fclose(l); }
#endif
#ifdef CONFIRM
#if defined(START_DELAY) || defined(START_CRASH)
  char first[256];
  snprintf(first, sizeof first, "%s %d", VERSION, (int)getpid());
  confirm(first);
#ifdef START_CRASH
  return 3;
#else
  sleep(START_DELAY);
#endif
#endif
  confirm(VERSION);
#endif
  return 0;
}
