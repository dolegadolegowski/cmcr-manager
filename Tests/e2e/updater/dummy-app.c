// Stand-in for CMCR Manager in the self-update tests (Tests/e2e/suites/updater.sh).
// Built with -DVERSION="\"1.2.3\"" and optionally -DCONFIRM="\"/path\"" (confirm the start like the real app)
// and -DLAUNCHLOG="\"/path\"" (record every launch).
#include <stdio.h>
#include <string.h>
#include <unistd.h>

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
  FILE *f = fopen(CONFIRM, "w");
  if (f) { fputs(VERSION, f); fclose(f); }
#endif
  return 0;
}
