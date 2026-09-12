#ifndef LSH_H_
#define LSH_H_

#include <stdbool.h>
#include <stddef.h>

enum Lsh_Types {
  Lsh_String = 0,
  Lsh_Int = 1,
  Lsh_Bool = 2,
  Lsh_Any = 3,
  Lsh_Expr,
};

enum Function_Type {
  LSH_CALLBACK,
};

#define VARIADIC (1 << 0)
#define OPTIONAL (2 << 0)

typedef struct {
  enum Lsh_Types type;
  int specialization;
} Lsh_Arg;

typedef struct {
  enum Lsh_Types type;

  union {
    const char *string;
    int integer;
    bool boolean;
    void *expr;
  };

} Lsh_Value;

typedef int (*Lsh_Callback)(int argc, const Lsh_Value *argv);

typedef struct {
  const char *name;

  Lsh_Callback callback;

  const Lsh_Arg *args;
  int nargs;

  enum Function_Type fn_type;
} Lsh_Plugin;

#endif // LSH_H_
