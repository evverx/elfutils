#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "fuzz.h"

int
main (int argc, char **argv)
{
  for (int i = 1; i < argc; i++)
    {
      fprintf (stderr, "Running: %s\n", argv[i]);

      FILE *f = fopen (argv[i], "r");
      assert (f);

      int p = fseek (f, 0, SEEK_END);
      assert (p >= 0);

      long len = ftell (f);
      assert (len >= 0);

      p = fseek (f, 0, SEEK_SET);
      assert (p >= 0);

      void *buf = malloc (len);
      assert (buf != NULL || len == 0);

      size_t n_read = fread (buf, 1, len, f);
      assert (n_read == (size_t) len);

      (void) fclose (f);

      int r = LLVMFuzzerTestOneInput (buf, len);

      /* Non-zero return values are reserved by LibFuzzer for future use
         https://llvm.org/docs/LibFuzzer.html#fuzz-target  */
      assert (r == 0);

      free (buf);

      fprintf (stderr, "Done:    %s: (%zd bytes)\n", argv[i], n_read);
    }
}
