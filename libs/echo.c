#include "lsh.h"
#include <stdarg.h>
#include <stdio.h>

static const Lsh_Arg args[] = {
    {Lsh_String, OPTIONAL},
};

static int callback(int argc, const Lsh_Value *argv) {
  int i;

  printf("you called 'echo'\n");

  if (argc == 0) {
    fputc('\n', stdout);
    return 0;
  }

  for (i = 0; i < argc; i++) {
    if (argv[i].type != Lsh_String)
      continue;

    printf("%s", argv[i].string);
  }
  fputc('\n', stdout);

  return 0;
}

Lsh_Plugin lsh_command(void) {
  return (Lsh_Plugin){
      .name = "echo",
      .callback = callback,
      .args = args,
      .nargs = 1,
      .fn_type = LSH_CALLBACK,
  };
}
